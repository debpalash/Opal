#!/usr/bin/env python3
"""Fetch and build pinned native libraries for the Android arm64 host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.zig-cache/android-native'
PREFIX = CACHE / 'prefix'
OUT = ROOT / 'zig-out/android'
API = '26'
MANIFEST = ROOT / 'mobile/android/dependencies.json'


def unsafe_member(name):
    p = Path(name)
    return p.is_absolute() or '..' in p.parts


def safe_extract_tar(archive, dest):
    with tarfile.open(archive) as t:
        for m in t.getmembers():
            if unsafe_member(m.name) or ((m.issym() or m.islnk()) and unsafe_member(m.linkname)) or m.isdev():
                raise ValueError('Unsafe archive member: ' + m.name)
        t.extractall(dest)


def safe_extract_zip(archive, dest):
    with zipfile.ZipFile(archive) as z:
        for n in z.namelist():
            if unsafe_member(n):
                raise ValueError('Unsafe archive member: ' + n)
        z.extractall(dest)


def safe_extract(archive, dest):
    if str(archive).endswith('.zip'):
        safe_extract_zip(archive, dest)
    else:
        safe_extract_tar(archive, dest)


def manifest():
    return json.loads(MANIFEST.read_text())


def fetch(item, dest_dir):
    """Download, verify sha256, extract once; returns the single top-level dir."""
    marker = dest_dir / '.checksum'
    if marker.exists() and marker.read_text() == item['sha256']:
        return next(p for p in dest_dir.iterdir() if p.is_dir())
    if dest_dir.exists():
        shutil.rmtree(dest_dir)
    dest_dir.mkdir(parents=True)
    with tempfile.TemporaryDirectory(dir=CACHE, prefix='download-') as tmp:
        archive = Path(tmp) / Path(item['url']).name
        digest = hashlib.sha256()
        req = urllib.request.Request(item['url'], headers={'User-Agent': 'Opal-Android-build'})
        with urllib.request.urlopen(req, timeout=120) as r, archive.open('wb') as out:
            while chunk := r.read(1024 * 1024):
                digest.update(chunk)
                out.write(chunk)
        if digest.hexdigest() != item['sha256']:
            raise ValueError('Checksum mismatch: ' + item['name'])
        safe_extract(archive, dest_dir)
    marker.write_text(item['sha256'])
    print('Ready: ' + item['name'], flush=True)
    return next(p for p in dest_dir.iterdir() if p.is_dir())


def run(cmd, **kw):
    print('+ ' + ' '.join(map(str, cmd)), flush=True)
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def ndk_root():
    version = manifest()['ndk']['version']
    for c in (os.environ.get('ANDROID_NDK_ROOT'),
              os.path.join(os.environ.get('ANDROID_HOME', ''), 'ndk', version),
              '/opt/homebrew/share/android-commandlinetools/ndk/' + version):
        if c and Path(c).is_dir():
            return Path(c)
    raise SystemExit('Android NDK ' + version + ' not found (set ANDROID_NDK_ROOT)')


def toolchain_dir(ndk):
    return next((ndk / 'toolchains/llvm/prebuilt').iterdir())


def cmake_android(ndk, extra):
    return ['-DCMAKE_TOOLCHAIN_FILE=' + str(ndk / 'build/cmake/android.toolchain.cmake'),
            '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=' + API, '-DANDROID_STL=c++_shared',
            '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_INSTALL_PREFIX=' + str(PREFIX),
            '-DCMAKE_PREFIX_PATH=' + str(PREFIX), '-GNinja', *extra]


def source(name):
    item = next(s for s in manifest()['sources'] if s['name'] == name)
    return item, fetch(item, CACHE / 'sources' / name)


def build_sdl3(ndk):
    _, src = source('sdl3')
    build = CACHE / 'build/sdl3'
    run(['cmake', '-S', src, '-B', build, *cmake_android(ndk, ['-DSDL_SHARED=ON', '-DSDL_STATIC=OFF',
         '-DSDL_TESTS=OFF', '-DSDL_EXAMPLES=OFF'])])
    run(['cmake', '--build', build, '--target', 'install'])
    java = OUT / 'sdl-java'
    if java.exists():
        shutil.rmtree(java)
    # Java package root: sdl-java/org/libsdl/app/*.java
    shutil.copytree(src / 'android-project/app/src/main/java/org', java / 'org')


def build_openssl(ndk):
    _, src = source('openssl')
    tc = toolchain_dir(ndk)
    env = dict(os.environ, ANDROID_NDK_ROOT=str(ndk), PATH=str(tc / 'bin') + os.pathsep + os.environ['PATH'])
    run(['./Configure', 'android-arm64', '-D__ANDROID_API__=' + API, 'no-shared', 'no-tests', 'no-apps',
         '--prefix=' + str(PREFIX), '--libdir=lib'], cwd=src, env=env)
    run(['make', '-j4', 'build_libs'], cwd=src, env=env)
    run(['make', 'install_dev'], cwd=src, env=env)


def build_webp(ndk):
    _, src = source('libwebp')
    build = CACHE / 'build/libwebp'
    run(['cmake', '-S', src, '-B', build, *cmake_android(ndk, ['-DBUILD_SHARED_LIBS=OFF', '-DWEBP_BUILD_ANIM_UTILS=OFF',
         '-DWEBP_BUILD_CWEBP=OFF', '-DWEBP_BUILD_DWEBP=OFF', '-DWEBP_BUILD_GIF2WEBP=OFF', '-DWEBP_BUILD_IMG2WEBP=OFF',
         '-DWEBP_BUILD_VWEBP=OFF', '-DWEBP_BUILD_WEBPINFO=OFF', '-DWEBP_BUILD_WEBPMUX=OFF', '-DWEBP_BUILD_EXTRAS=OFF'])])
    run(['cmake', '--build', build, '--target', 'install'])


def build_sqlite(ndk):
    _, src = source('sqlite')
    clang = toolchain_dir(ndk) / 'bin' / ('aarch64-linux-android' + API + '-clang')
    obj = CACHE / 'build/sqlite3.o'
    obj.parent.mkdir(parents=True, exist_ok=True)
    run([clang, '-O2', '-fPIC', '-DSQLITE_ENABLE_FTS5', '-DSQLITE_THREADSAFE=1', '-c', src / 'sqlite3.c', '-o', obj])
    (PREFIX / 'lib').mkdir(parents=True, exist_ok=True)
    (PREFIX / 'include').mkdir(parents=True, exist_ok=True)
    lib = PREFIX / 'lib/libsqlite3.a'
    lib.unlink(missing_ok=True)
    run([toolchain_dir(ndk) / 'bin/llvm-ar', 'rcs', lib, obj])
    for h in ('sqlite3.h', 'sqlite3ext.h'):
        shutil.copy2(src / h, PREFIX / 'include' / h)


def build_torrent(ndk):
    item, src = source('libtorrent')
    _, boost = source('boost')
    build = CACHE / 'build/libtorrent'
    run(['cmake', '-S', src, '-B', build, *cmake_android(ndk, ['-DBUILD_SHARED_LIBS=OFF', '-Dwebtorrent=OFF',
         '-Dbuild_tests=OFF', '-Dbuild_examples=OFF', '-Dbuild_tools=OFF', '-Dpython-bindings=OFF',
         '-DBoost_INCLUDE_DIR=' + str(boost), '-DOPENSSL_ROOT_DIR=' + str(PREFIX),
         '-DOPENSSL_USE_STATIC_LIBS=ON', '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-Wno-dev'])])
    run(['cmake', '--build', build, '--target', 'install'])
    # Use the exact ABI/feature definitions from the library's own build.
    import shlex
    command = shlex.split(json.loads((build / 'compile_commands.json').read_text())[0]['command'])
    flags, i = [], 1
    while i < len(command):
        v = command[i]
        if v in ('-o', '-c', '-MF', '-MT'):
            i += 2
            continue
        if v in ('-MD', '-MMD') or v == '-DTORRENT_BUILDING_LIBRARY' or v.startswith('-W'):
            i += 1
            continue
        flags.append(v)
        i += 1
    flags = [f for f in flags if not (f.endswith('.cpp') or f.endswith('.o'))]
    obj = CACHE / 'build/torrent_wrapper.o'
    run([command[0], *flags, '-I' + str(boost), '-c', ROOT / 'src/torrent_wrapper.cpp', '-o', obj])
    lib = PREFIX / 'lib/libopal_torrent.a'
    lib.unlink(missing_ok=True)
    run([toolchain_dir(ndk) / 'bin/llvm-ar', 'rcs', lib, obj])
    shutil.copy2(ROOT / 'src/torrent_wrapper.h', PREFIX / 'include/torrent_wrapper.h') if (ROOT / 'src/torrent_wrapper.h').exists() else None


MESON_MIN = (1, 11)
MPV_OUTPUTS = ('include/mpv/client.h', 'lib/libmpv.so')


def meson_version_ok(text):
    """mpv-android's fontconfig requires meson >= 1.11 (Ubuntu 24.04 apt ships 1.3.2)."""
    parts = text.strip().split('.')
    try:
        return tuple(int(p) for p in parts[:2]) >= MESON_MIN
    except ValueError:
        return False


def missing_mpv_outputs(prefix):
    return [rel for rel in MPV_OUTPUTS if not (Path(prefix) / rel).is_file()]


def merge_tree(src, dst):
    """Copy src into dst, replacing existing files and symlinks. A cached prefix
    already holds mpv-android's symlinks (liblinebreak.a -> libunibreak.a);
    copytree(dirs_exist_ok=True, symlinks=True) raises FileExistsError on them."""
    src, dst = Path(src), Path(dst)
    for path in sorted(src.rglob('*')):
        target = dst / path.relative_to(src)
        if path.is_dir() and not path.is_symlink():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink() or target.exists():
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            else:
                target.unlink()
        if path.is_symlink():
            os.symlink(os.readlink(path), target)
        else:
            shutil.copy2(path, target)


def build_mpv(ndk):
    # mpv-android fetches/uses its own pinned SDK+NDK under buildscripts/sdk (the NDK arg is unused).
    _, src = source('mpv-android')
    scripts = src / 'buildscripts'
    out = subprocess.run(['meson', '--version'], capture_output=True, text=True)
    if out.returncode != 0 or not meson_version_ok(out.stdout):
        raise SystemExit('meson >= %d.%d required (found %r); pip install meson' % (*MESON_MIN, out.stdout.strip()))
    # IN_CI=1: skip sudo package installs and shallow-clone the pinned ffmpeg.
    env = dict(os.environ, IN_CI='1')
    env.pop('ANDROID_NDK_ROOT', None)
    # `bash -e`: the scripts' shebang `-e` is ignored when invoked as `bash script`, which let
    # failed dependency builds (fontconfig) be silently skipped.
    run(['bash', '-e', 'download.sh'], cwd=scripts, env=env)
    run(['bash', '-e', 'buildall.sh', '--arch', 'arm64', 'mpv'], cwd=scripts, env=env)
    built = scripts / 'prefix/arm64'
    missing = missing_mpv_outputs(built)
    if missing:
        raise SystemExit('mpv-android build produced no ' + ', '.join(missing) + ' in ' + str(built))
    for sub in ('include', 'lib'):
        merge_tree(built / sub, PREFIX / sub)
    missing = missing_mpv_outputs(PREFIX)
    if missing:
        raise SystemExit('prefix is missing ' + ', '.join(missing) + ' after mpv copy')


def pick_libcxx(ndk):
    """libc++_shared.so to bundle. libmpv and its deps are built by mpv-android
    with its own (newer) NDK and import symbols our NDK's libc++ lacks
    (std::__from_chars_floating_point<float> from r30), so dlopen("libmpv.so")
    failed on device. libc++ is backward compatible: ship the newest one, i.e.
    mpv-android's when present."""
    mpv_ndk = sorted(CACHE.glob('sources/mpv-android/*/buildscripts/sdk/*/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so'))
    if mpv_ndk:
        return mpv_ndk[-1]
    return toolchain_dir(ndk) / 'sysroot/usr/lib/aarch64-linux-android/libc++_shared.so'


def install_jnilibs(ndk):
    dest = OUT / 'jniLibs/arm64-v8a'
    dest.mkdir(parents=True, exist_ok=True)
    for so in (PREFIX / 'lib').glob('*.so'):
        shutil.copy2(so, dest / so.name)
    stl = pick_libcxx(ndk)
    shutil.copy2(stl, dest / stl.name)
    # Keep the prefix self-contained so a CI artifact works with --deps-prefix.
    shutil.copy2(stl, PREFIX / 'lib' / stl.name)
    if (OUT / 'sdl-java').is_dir():
        merge_tree(OUT / 'sdl-java', PREFIX / 'sdl-java')


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    ndk = ndk_root()
    PREFIX.mkdir(parents=True, exist_ok=True)
    build_openssl(ndk)
    build_sqlite(ndk)
    build_webp(ndk)
    build_sdl3(ndk)
    build_torrent(ndk)
    build_mpv(ndk)
    install_jnilibs(ndk)
    print('Android deps ready: ' + str(PREFIX), flush=True)


if __name__ == '__main__':
    argparse.ArgumentParser(description=__doc__).parse_args()
    prepare()
