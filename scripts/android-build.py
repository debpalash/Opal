#!/usr/bin/env python3
"""Build the Opal Android APK (arm64-v8a): native deps -> libmain.so -> Gradle."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
NDK_VERSION = '27.1.12297006'
API = '26'
OUT = ROOT / 'zig-out/android'


def app_version():
    return re.search(r'\.version\s*=\s*"([^"]+)"', (ROOT / 'build.zig.zon').read_text())[1]


def version_code(version):
    major, minor, patch = (int(p) for p in re.match(r'(\d+)\.(\d+)\.(\d+)', version).groups())
    return major * 10000 + minor * 100 + patch


def find_ndk():
    for c in (os.environ.get('ANDROID_NDK_ROOT'),
              os.path.join(os.environ.get('ANDROID_HOME', ''), 'ndk', NDK_VERSION),
              '/opt/homebrew/share/android-commandlinetools/ndk/' + NDK_VERSION):
        if c and Path(c).is_dir():
            return Path(c)
    raise SystemExit('Android NDK ' + NDK_VERSION + ' not found (set ANDROID_NDK_ROOT)')


def find_jdk():
    candidates = [os.environ.get('JAVA_HOME'), '/opt/homebrew/opt/openjdk@21', '/opt/homebrew/opt/openjdk@17']
    for c in candidates:
        if not c or not (Path(c) / 'bin/java').exists():
            continue
        out = subprocess.run([str(Path(c) / 'bin/java'), '-version'], capture_output=True, text=True).stderr
        m = re.search(r'version "(\d+)', out)
        if m and int(m[1]) in (17, 21):
            return c
    raise SystemExit('JDK 17 or 21 required (newer JDKs are rejected); set JAVA_HOME')


def run(cmd, **kw):
    print('+ ' + ' '.join(map(str, cmd)), flush=True)
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def write_assets():
    assets = OUT / 'assets'
    assets.mkdir(parents=True, exist_ok=True)
    for c in ('/etc/ssl/certs/ca-certificates.crt', '/etc/ssl/cert.pem'):
        if Path(c).exists():
            shutil.copy2(c, assets / 'cacert.pem')
            break
    else:
        raise SystemExit('No CA bundle found for cacert.pem')
    manifest = ROOT / 'plugins-manifest.json'
    for candidate in (manifest, ROOT / 'plugins/plugins-manifest.json', ROOT / 'assets/plugins-manifest.json'):
        if candidate.exists():
            shutil.copy2(candidate, assets / 'plugins-manifest.json')
            break
    else:
        (assets / 'plugins-manifest.json').write_text('[]\n')
    icon = OUT / 'res/mipmap-xxxhdpi'
    icon.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'assets/opal_logo.png', icon / 'ic_launcher.png')


def stub_libs():
    """Empty placeholder libs so Gradle packaging can be exercised without a native build."""
    d = OUT / 'jniLibs/arm64-v8a'
    d.mkdir(parents=True, exist_ok=True)
    for n in ('libSDL3.so', 'libmain.so'):
        (d / n).write_bytes(b'')


def ndk_bin(ndk):
    return next((ndk / 'toolchains/llvm/prebuilt').glob('*/bin'))


def find_unwind(ndk):
    """libunwind.a for aarch64: NDK clang links it into every .so; Zig does not,
    leaving `_Unwind_Resume` unresolved and dlopen of libmain.so failing."""
    hits = sorted((ndk / 'toolchains/llvm/prebuilt').glob('*/lib/clang/*/lib/linux/aarch64/libunwind.a'))
    if not hits:
        raise SystemExit('libunwind.a not found in NDK ' + str(ndk))
    return hits[-1]


def unresolved_symbols(undefined, provided):
    """Strong undefined symbols of libmain.so that no loaded library defines.
    Symbol versions (`name@@VER`) are stripped on both sides."""
    strip = lambda n: n.split('@', 1)[0]
    have = {strip(n) for n in provided}
    return sorted({strip(n) for n in undefined} - have)


def verify_libmain(ndk):
    """Fail the build if libmain.so would not dlopen: every strong undefined
    symbol must come from a bundled .so or the API-level NDK system libs."""
    nm = ndk_bin(ndk) / 'llvm-nm'
    jni = OUT / 'jniLibs/arm64-v8a'
    def syms(path, *flags):
        out = subprocess.run([str(nm), '-D', *flags, str(path)], capture_output=True, text=True, check=True).stdout
        return [line.split()[-1] for line in out.splitlines() if line.strip()]
    undefined = [l for l in subprocess.run([str(nm), '-D', '-u', str(jni / 'libmain.so')], capture_output=True, text=True, check=True).stdout.splitlines() if l.strip().startswith('U ')]
    undefined = [l.split()[-1] for l in undefined]
    provided = []
    sysroot_api = next((ndk / 'toolchains/llvm/prebuilt').glob('*/sysroot')) / 'usr/lib/aarch64-linux-android' / API
    for lib in list(jni.glob('*.so')) + list(sysroot_api.glob('*.so')):
        # Some NDK .so files (libc++.so) are linker scripts, not ELF.
        if lib.name != 'libmain.so' and lib.open('rb').read(4) == b'\x7fELF':
            provided += syms(lib, '--defined-only')
    missing = unresolved_symbols(undefined, provided)
    if missing:
        raise SystemExit('libmain.so has unresolved symbols (dlopen would fail): ' + ', '.join(missing[:40]))
    print(f'libmain.so: {len(undefined)} imports, all resolved', flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--deps-prefix', help='prebuilt native prefix; skips building dependencies')
    ap.add_argument('--skip-zig', action='store_true')
    ap.add_argument('--stub-libs', action='store_true')
    ap.add_argument('--apk', help='copy the release APK here')
    ap.add_argument('--install', action='store_true')
    ap.add_argument('--launch', action='store_true')
    a = ap.parse_args()
    version = app_version()
    ndk = find_ndk()
    env = dict(os.environ, ANDROID_NDK_ROOT=str(ndk))
    prefix = Path(a.deps_prefix).resolve() if a.deps_prefix else ROOT / '.zig-cache/android-native/prefix'
    if not a.deps_prefix and not a.stub_libs:
        run([sys.executable, '-u', ROOT / 'scripts/android-deps.py'])
    if a.stub_libs:
        stub_libs()
    elif not a.skip_zig:
        run(['zig', 'build', '--build-file', ROOT / 'build-android.zig', 'so', '--release=fast', '-Dndk=' + str(ndk),
             '-Dapi=' + API, '-Ddeps-prefix=' + str(prefix), '-Dversion=' + version, '-fsys=sdl3',
             '-Dunwind=' + str(find_unwind(ndk)), '--prefix', OUT], cwd=ROOT, env=env)
    write_assets()
    if a.deps_prefix:
        # Pre-built prefixes ship the runtime libs and SDL Java alongside the headers.
        jni = OUT / 'jniLibs/arm64-v8a'
        jni.mkdir(parents=True, exist_ok=True)
        for so in (prefix / 'lib').glob('*.so'):
            shutil.copy2(so, jni / so.name)
        for d in (prefix / 'jniLibs/arm64-v8a',):
            if d.is_dir():
                for so in d.glob('*.so'):
                    shutil.copy2(so, jni / so.name)
        java = prefix / 'sdl-java'
        if java.is_dir() and not (OUT / 'sdl-java').exists():
            shutil.copytree(java, OUT / 'sdl-java')
    if not a.stub_libs and not a.skip_zig:
        verify_libmain(ndk)
    jdk = find_jdk()
    genv = dict(env, JAVA_HOME=jdk)
    sdk = os.environ.get('ANDROID_HOME') or str(ndk.parents[1])
    genv['ANDROID_HOME'] = sdk
    run(['gradle', '-p', ROOT / 'mobile/android', 'assembleRelease', '-PsdlJavaDir=' + str(OUT / 'sdl-java')], env=genv)
    apk = ROOT / 'mobile/android/app/build/outputs/apk/release/app-release.apk'
    if not apk.exists():
        raise SystemExit('APK not produced: ' + str(apk))
    target = Path(a.apk) if a.apk else ROOT / 'dist' / f'Opal-{version}-android.apk'
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(apk, target)
    print('APK: ' + str(target), flush=True)
    if a.install or a.launch:
        run(['adb', 'install', '-r', target])
    if a.launch:
        run(['adb', 'shell', 'am', 'start', '-n', 'com.debpalash.opal/.OpalActivity'])


if __name__ == '__main__':
    main()
