# Linux compatibility package

`opal_<version>_compat_amd64.deb` is compiled on Ubuntu 20.04, including its
private mpv 0.41, FFmpeg 7.1, SDL 2.30, libtorrent 2.0, SQLite 3.53 and OpenSSL 3.6 runtime.
It requires glibc 2.31 and x86-64-v2. It installs without replacing system
libraries. The normal installer selects this package on older Debian/Ubuntu
hosts; both system installation and user-local extraction are supported.

Playback uses mpv's software renderer and software decoding. Desktop display
uses X11 (XWayland on Wayland). Use the standard package on modern systems for
native Wayland and the distribution's hardware decoding stack.

Reproduce the package with `packaging/linux-compat/build.sh`. CI installs the
result on a clean Ubuntu 20.04 image and checks actual GUI/API initialization,
account creation, protected API access, resource serving and video playback. Every staged ELF is checked for a
glibc requirement no newer than 2.31; the loader and glibc are never bundled.

The checksum-verified upstream archives, source URLs and build scripts are
published with the release as `opal-<version>-linux-compat-sources.tar.gz`.
Opal and mpv are distributed under GPL version 3; FFmpeg under LGPL version 3
(the `--enable-version3` configuration uses OpenSSL under Apache 2.0).
libplacebo is LGPL 2.1 or later, SDL is zlib, libtorrent is BSD-3-Clause, and
OpenSSL is Apache 2.0 and SQLite is public domain. The archives include each dependency's license. Host
system libraries are installed by apt, rather than copied into the package.
