#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/build-common.sh"
fetch libplacebo-6.338.2 https://github.com/haasn/libplacebo/archive/refs/tags/v6.338.2.tar.gz 2f1e624e09d72a8c9db70f910f7560e764a1c126dae42acc5b3bcef836a7aec6
# GitHub source archives omit submodules. GCC 9 needs the upstream pinned
# fast_float implementation because libstdc++ lacks floating from_chars.
fetch fast-float-2b2395f9ac836ffca6404424bcc252bff7aa80e4 https://github.com/fastfloat/fast_float/archive/2b2395f9ac836ffca6404424bcc252bff7aa80e4.tar.gz 230d20e4e4ac1f6a9df92c4d746c6ec536cdb0c085bc8635d4b88cead5dc22cb
mkdir -p "$WORK/libplacebo-6.338.2/3rdparty/fast_float"
cp -R "$WORK/fast_float-2b2395f9ac836ffca6404424bcc252bff7aa80e4/." "$WORK/libplacebo-6.338.2/3rdparty/fast_float/"
# Public Vulkan types are needed by the disabled-backend stubs as well.
fetch vulkan-headers-d732b2de303ce505169011d438178191136bfb00 https://github.com/KhronosGroup/Vulkan-Headers/archive/d732b2de303ce505169011d438178191136bfb00.tar.gz 570f9ae1e65466dbaf5fcab667abd079dd0a61c4ab86cf535efd492bf70a5b74
mkdir -p "$WORK/libplacebo-6.338.2/3rdparty/Vulkan-Headers" "$PREFIX/include"
cp -R "$WORK/Vulkan-Headers-d732b2de303ce505169011d438178191136bfb00/." "$WORK/libplacebo-6.338.2/3rdparty/Vulkan-Headers/"
cp -R "$WORK/Vulkan-Headers-d732b2de303ce505169011d438178191136bfb00/include/." "$PREFIX/include/"
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
