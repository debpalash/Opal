#!/usr/bin/env python3
"""Fetch pinned native libraries; retain the requested arm64 iOS slice only."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import shlex
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.zig-cache/ios-native'
SIMULATOR = False


def device_slice(manifest):
    return platform_slice(manifest, False)


def platform_slice(manifest, simulator):
    for library in manifest.get('AvailableLibraries', []):
        if (library.get('SupportedPlatform') == 'ios'
                and (library.get('SupportedPlatformVariant') == 'simulator' if simulator else not library.get('SupportedPlatformVariant'))
                and 'arm64' in library.get('SupportedArchitectures', [])):
            identifier = library['LibraryIdentifier']
            path = library['LibraryPath']
            if '/' in identifier or '..' in identifier or '/' in path or '..' in path:
                raise ValueError('Invalid framework path')
            return identifier, path
    raise ValueError('No matching arm64 iOS slice')


def fetch_library(item):
    destination = CACHE / 'frameworks' / item['name']
    marker = destination / '.checksum'
    if marker.exists() and marker.read_text() == item['sha256']:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=CACHE, prefix='download-') as temporary:
        archive = Path(temporary) / 'library.zip'
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'Opal-iOS-build'})
        digest = hashlib.sha256()
        with urllib.request.urlopen(request, timeout=90) as response, archive.open('wb') as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != item['sha256']:
            raise ValueError('Checksum mismatch: ' + item['name'])
        with zipfile.ZipFile(archive) as source:
            manifests = [name for name in source.namelist() if name.endswith('.xcframework/Info.plist')]
            if len(manifests) != 1:
                raise ValueError('Ambiguous XCFramework manifest')
            info = manifests[0]
            identifier, library_path = platform_slice(plistlib.loads(source.read(info)), SIMULATOR)
            prefix = info.removesuffix('Info.plist') + identifier + '/'
            staging = Path(temporary) / 'device'
            staging.mkdir()
            for member in source.infolist():
                if not member.filename.startswith(prefix) or member.is_dir():
                    continue
                relative = Path(member.filename[len(prefix):])
                if relative.is_absolute() or '..' in relative.parts:
                    raise ValueError('Invalid archive path')
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(member) as data, target.open('wb') as output:
                    shutil.copyfileobj(data, output)
            if not (staging / library_path).exists():
                raise ValueError('Framework missing')
            if destination.exists():
                shutil.rmtree(destination)
            shutil.move(staging, destination)
            marker.write_text(item['sha256'])
    print('Device library ready: ' + item['name'], flush=True)


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    libraries = json.loads((ROOT / 'mobile/ios/dependencies.json').read_text())['libraries']
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
        list(workers.map(fetch_library, libraries))


def prepare_torrent():
    item = json.loads((ROOT / 'mobile/ios/torrent-dependency.json').read_text())
    sources = CACHE / 'sources'
    source = sources / ('libtorrent-rasterbar-' + item['version'])
    if not source.exists():
        sources.mkdir(parents=True, exist_ok=True)
        request = urllib.request.Request(item['url'], headers={'User-Agent': 'Opal-iOS-build'})
        with urllib.request.urlopen(request, timeout=90) as response:
            data = response.read(32 * 1024 * 1024)
        if hashlib.sha256(data).hexdigest() != item['sha256']:
            raise ValueError('libtorrent source checksum mismatch')
        import io
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive.getmembers():
                if Path(member.name).is_absolute() or '..' in Path(member.name).parts or member.issym() or member.islnk():
                    raise ValueError('Unsafe libtorrent source path')
            archive.extractall(sources)
    sdk_name = 'iphonesimulator' if SIMULATOR else 'iphoneos'
    sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()
    prefix = Path(__import__('os').environ.get('HOMEBREW_PREFIX', '/opt/homebrew'))
    build = CACHE / 'torrent-build'
    ssl = CACHE / 'frameworks/Libssl/Libssl.framework'
    crypto = CACHE / 'frameworks/Libcrypto/Libcrypto.framework'
    subprocess.run(['cmake', '-S', source, '-B', build, '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=' + sdk,
                    '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0', '-DCMAKE_BUILD_TYPE=Release',
                    '-DBUILD_SHARED_LIBS=OFF', '-Dwebtorrent=OFF', '-Dbuild_tests=OFF', '-Dbuild_examples=OFF', '-Dbuild_tools=OFF',
                    '-Dpython-bindings=OFF', '-DBoost_INCLUDE_DIR=' + str(prefix / 'include'), '-DOPENSSL_INCLUDE_DIR=' + str(ssl / 'Headers'),
                    '-DOPENSSL_SSL_LIBRARY=' + str(ssl / 'Libssl'), '-DOPENSSL_CRYPTO_LIBRARY=' + str(crypto / 'Libcrypto'),
                    '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON', '-Wno-dev'], check=True)
    subprocess.run(['cmake', '--build', build, '--parallel', '4'], check=True)
    # Use the exact ABI/feature definitions from the library's own build.
    command = shlex.split(json.loads((build / 'compile_commands.json').read_text())[0]['command'])
    flags = []
    i = 1
    while i < len(command):
        value = command[i]
        if value in ('-o', '-c'):
            i += 2
            continue
        if value == '-DTORRENT_BUILDING_LIBRARY' or value.startswith('-W'):
            i += 1
            continue
        flags.append(value)
        i += 1
    output = CACHE / 'libopal_torrent.a'
    if not output.exists() or max((ROOT / f).stat().st_mtime for f in ['src/torrent_wrapper.cpp', 'src/torrent_memory.hpp']) > output.stat().st_mtime:
        obj = CACHE / 'torrent_wrapper.o'
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang++', *flags, '-c', ROOT / 'src/torrent_wrapper.cpp', '-o', obj], check=True)
        subprocess.run(['xcrun', 'ar', 'rcs', output, obj], check=True)
    lib_dir = ROOT / ('zig-out/ios-simulator/lib' if SIMULATOR else 'zig-out/ios/lib')
    lib_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(output, lib_dir / output.name)
    shutil.copy2(build / 'libtorrent-rasterbar.a', lib_dir / 'libtorrent-rasterbar.a')


def project_dependencies():
    lines = ['targets:', '  Opal:', '    dependencies:']
    frameworks = sorted((CACHE / 'frameworks').glob('*/*.framework'))
    for framework in frameworks:
        lines.extend(['      - framework: ' + str(framework), '        embed: false'])
    for archive in sorted((CACHE / 'frameworks').glob('*/*.a')):
        lib_dir = ROOT / ('zig-out/ios-simulator/lib' if SIMULATOR else 'zig-out/ios/lib')
        shutil.copy2(archive, lib_dir / archive.name)
        lines.extend(['      - framework: ' + str(archive), '        embed: false'])
    for library in [CACHE / 'libopal_torrent.a', CACHE / 'torrent-build/libtorrent-rasterbar.a']:
        lines.extend(['      - framework: ' + str(library), '        embed: false'])
    (ROOT / 'mobile/ios/native-libraries.yml').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', action='store_true')
    args = parser.parse_args()
    SIMULATOR = args.simulator
    if SIMULATOR:
        CACHE = ROOT / '.zig-cache/ios-native-simulator'
    prepare()
    prepare_torrent()
    project_dependencies()
