#!/usr/bin/env python3
"""Build/install Opal on a physical iOS device or an explicitly selected Simulator."""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.debpalash.opal.ios'
OUTPUT = ROOT / '.zig-cache/ios-xcode/Build/Products/Release-iphoneos/Opal.app'


def simulator_device(requested=None):
    data = json.loads(capture(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
    devices = [d for rows in data.get('devices', {}).values() for d in rows if d.get('isAvailable') and 'iPhone' in d.get('name', '')]
    if requested:
        devices = [d for d in devices if requested in (d['udid'], d['name'])]
    if not devices:
        raise RuntimeError('No installed iPhone Simulator is available.')
    devices.sort(key=lambda d: d.get('state') != 'Booted')
    return devices[0]


def run(argv, **kwargs):
    return subprocess.run([str(x) for x in argv], cwd=ROOT, check=True, **kwargs)


def capture(argv):
    return run(argv, capture_output=True, text=True).stdout


def playback_smoke(command, stop_command, timeout=30):
    """Require an advancing shared-player clock AND a displayed video frame.

    A hung main thread cannot fire its timer. Bound that case from the host
    and always stop the test app so a failed test cannot leave it spinning.
    """
    with tempfile.TemporaryDirectory(prefix='opal-ios-smoke-') as temp, open(Path(temp) / 'console', 'w') as output, open(Path(temp) / 'console', errors='replace') as reader:
        process = subprocess.Popen([str(x) for x in command], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        transcript = ''
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                chunk = reader.read()
                transcript += chunk
                if 'OPAL_IOS_SHARED_PLAYER_OK ' in transcript:
                    print(next(line for line in transcript.splitlines() if 'OPAL_IOS_SHARED_PLAYER_OK ' in line), flush=True)
                    return
                if 'OPAL_IOS_SHARED_PLAYER_FAILED ' in transcript or process.poll() is not None:
                    raise RuntimeError('Shared player playback failed:\n' + transcript[-4000:])
                time.sleep(0.05)
            raise RuntimeError('Shared player playback timed out:\n' + transcript[-4000:])
        finally:
            try:
                if callable(stop_command):
                    stop_command()
                else:
                    subprocess.run([str(x) for x in stop_command], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


def prepare_zig_library(source, destination):
    """Local workaround for Zig 0.17's iOS processReplace/NullFile bug.

    iOS cannot replace its process. The incorrect std.process capability flag
    otherwise instantiates Darwin spawn code and prevents ALL Threaded I/O.
    Only this build uses the overlay; the installed compiler stays untouched.
    """
    process = source / 'std/process.zig'
    text = process.read_text()
    declaration = text.split('pub const can_replace = switch (native_os) {', 1)[-1].split('};', 1)[0]
    if '.ios' in declaration:
        return source
    old = '.windows, .haiku, .wasi => false,'
    if old not in declaration:
        raise RuntimeError('Unrecognized Zig process capability declaration; review the iOS toolchain workaround.')
    patched = text.replace(old, '.windows, .haiku, .wasi, .ios, .tvos, .visionos, .watchos => false,', 1)
    destination = destination / hashlib.sha256((str(source) + text).encode()).hexdigest()[:16]
    def mirror(src, dst):
        dst.mkdir(parents=True, exist_ok=True)
        for item in src.iterdir():
            target = dst / item.name
            if item == process:
                if not target.exists() or target.read_text() != patched:
                    target.write_text(patched)
            elif item == source / 'std':
                mirror(item, target)
            elif not target.exists():
                target.symlink_to(item.resolve(), target_is_directory=item.is_dir())
    mirror(source, destination)
    return destination


def zig_library():
    environment = capture(['zig', 'env'])
    match = re.search(r'\.lib_dir = "([^"]+)"', environment)
    if not match:
        raise RuntimeError('Could not find the Zig 0.17 library directory.')
    return prepare_zig_library(Path(match[1]), ROOT / '.zig-cache/ios-zig-lib')


def physical_device(requested=None):
    with tempfile.TemporaryDirectory(prefix='opal-ios-device-') as temp:
        path = Path(temp) / 'devices.json'
        run(['xcrun', 'devicectl', 'list', 'devices', '--json-output', path], stdout=subprocess.DEVNULL)
        devices = json.loads(path.read_text()).get('result', {}).get('devices', [])
    physical = [d for d in devices if d.get('hardwareProperties', {}).get('reality') == 'physical'
                and d.get('connectionProperties', {}).get('pairingState') == 'paired']
    if requested:
        physical = [d for d in physical if requested in (d['identifier'], d['hardwareProperties'].get('udid'), d.get('deviceProperties', {}).get('name'))]
    if len(physical) != 1:
        raise RuntimeError('Connect one paired iPhone/iPad, or choose it with --device.')
    item = physical[0]
    return item['identifier'], item['hardwareProperties']['udid']


def stop_physical_app(device):
    with tempfile.TemporaryDirectory(prefix='opal-ios-processes-') as temp:
        path = Path(temp) / 'processes.json'
        run(['xcrun', 'devicectl', 'device', 'info', 'processes', '--device', device, '--json-output', path], capture_output=True, timeout=10)
        for process in json.loads(path.read_text()).get('result', {}).get('runningProcesses', []):
            if process.get('executable', '').endswith('/Opal.app/Opal'):
                run(['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', device, '--pid', str(process['processIdentifier']), '--kill'], capture_output=True, timeout=10)


def matching_profile(profile, udid, identities, now=None):
    now = now or datetime.datetime.utcnow()
    entitlements = profile.get('Entitlements', {})
    app_id = entitlements.get('application-identifier', '')
    prefix, _, pattern = app_id.partition('.')
    if not pattern or not fnmatch.fnmatchcase(BUNDLE, pattern):
        return None
    if udid not in profile.get('ProvisionedDevices', []) or profile.get('ExpirationDate', now) <= now:
        return None
    if not entitlements.get('get-task-allow'):
        return None
    for certificate in profile.get('DeveloperCertificates', []):
        fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        if fingerprint in identities:
            result = dict(entitlements)
            result['application-identifier'] = prefix + '.' + BUNDLE
            if 'keychain-access-groups' in result:
                result['keychain-access-groups'] = [x.replace('*', BUNDLE) for x in result['keychain-access-groups']]
            return fingerprint, result
    return None


def signing_profile(udid):
    identities = set(re.findall(r'\b[A-F0-9]{40}\b', capture(['security', 'find-identity', '-v', '-p', 'codesigning'])))
    for directory in [Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles', Path.home() / 'Library/MobileDevice/Provisioning Profiles']:
        for path in sorted(directory.glob('*.mobileprovision')):
            decoded = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
            if decoded.returncode:
                continue
            profile = plistlib.loads(decoded.stdout)
            matched = matching_profile(profile, udid, identities)
            if matched:
                return path, matched[0], matched[1]
    raise RuntimeError('No valid development signing profile covers Opal and this device. Configure development signing in Xcode.')


def assets():
    directory = ROOT / 'zig-out/ios-assets'
    icon = directory / 'Assets.xcassets/AppIcon.appiconset'
    icon.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / 'assets/opal_logo.png', icon / 'Opal.png')
    (icon / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'Opal.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}))
    shutil.copy2(ROOT / 'assets/opal_logo.png', directory / 'OpalBrand.png')
    # Source catalog: the connector endpoints Install/starter-pack writes
    # (plugin_repo.readLocalManifest reads <resource root>/plugins-manifest.json).
    shutil.copy2(ROOT / 'data/plugins-manifest.json', directory / 'plugins-manifest.json')
    # std.http has no iOS trust store; ship the build host's PEM roots.
    for source in ('/etc/ssl/cert.pem', '/opt/homebrew/etc/ca-certificates/cert.pem'):
        if Path(source).exists():
            shutil.copy2(source, directory / 'cacert.pem')
            break
    else:
        raise RuntimeError('No PEM CA bundle found on the build host (/etc/ssl/cert.pem).')
    preview = directory / 'OpalPreview.mp4'
    if not preview.exists():
        run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'lavfi', '-i', 'color=c=0x0b1510:s=640x360:r=24:d=12',
             '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100:duration=12', '-vf', 'drawbox=x=260:y=120:w=120:h=120:color=0x6bce9d:t=fill',
             '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '30', '-c:a', 'aac', '-b:a', '32k', '-af', 'volume=0.01', '-movflags', '+faststart', preview])


def build(simulator=False):
    sdk_name = 'iphonesimulator' if simulator else 'iphoneos'
    output = 'zig-out/ios-simulator' if simulator else 'zig-out/ios'
    sdk = capture(['xcrun', '--sdk', sdk_name, '--show-sdk-path']).strip()
    run(['python3', 'scripts/ios-deps.py', *(['--simulator'] if simulator else [])])
    run(['zig', 'build', '--build-file', 'build-ios.zig', 'lib', '--release=fast', '-Dsimulator=' + str(simulator).lower(), '-Dsdk-root=' + sdk, '--prefix', output], env={**os.environ, 'ZIG_LIB_DIR': str(zig_library())})
    assets()
    run(['xcodegen', 'generate', '--spec', 'mobile/ios/project.yml'])
    command = ['xcodebuild', '-project', 'mobile/ios/Opal.xcodeproj', '-scheme', 'Opal', '-configuration', 'Release', '-sdk', sdk_name,
               '-destination', 'generic/platform=iOS Simulator' if simulator else 'generic/platform=iOS',
               '-derivedDataPath', '.zig-cache/ios-simulator-xcode' if simulator else '.zig-cache/ios-xcode', 'CODE_SIGNING_ALLOWED=NO']
    if simulator:
        command += ['SUPPORTED_PLATFORMS=iphonesimulator', 'ARCHS=arm64', 'LIBRARY_SEARCH_PATHS=' + str(ROOT / output / 'lib'), 'HEADER_SEARCH_PATHS=' + str(ROOT / output / 'include')]
    run([*command, 'build'])


def install(device, udid):
    if not OUTPUT.exists():
        raise RuntimeError('Build the app first.')
    path, identity, entitlements = signing_profile(udid)
    shutil.copy2(path, OUTPUT / 'embedded.mobileprovision')
    target = ROOT / '.zig-cache/ios-entitlements.plist'
    target.write_bytes(plistlib.dumps(entitlements))
    run(['codesign', '--force', '--sign', identity, '--entitlements', target, '--generate-entitlement-der', '--timestamp=none', OUTPUT])
    run(['codesign', '--verify', '--strict', OUTPUT])
    run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, OUTPUT])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='Paired physical device name, UDID or CoreDevice ID')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--simulator', action='store_true', help='Use the installed arm64 iOS Simulator; never connects to the phone')
    parser.add_argument('--install', action='store_true')
    parser.add_argument('--launch', action='store_true')
    parser.add_argument('--smoke', action='store_true', help='Verify shared-player playback within 30 seconds, then stop the test app')
    args = parser.parse_args()
    if not args.skip_build:
        build(args.simulator)
    if args.simulator:
        device = simulator_device(args.device)
        identifier = device['udid']
        if device.get('state') != 'Booted':
            run(['xcrun', 'simctl', 'boot', identifier])
            run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'])
        if args.install:
            run(['xcrun', 'simctl', 'install', identifier, ROOT / '.zig-cache/ios-simulator-xcode/Build/Products/Release-iphonesimulator/Opal.app'])
        if args.launch or args.smoke:
            command = ['xcrun', 'simctl', 'launch', '--terminate-running-process']
            if args.smoke: command += ['--console']
            command += [identifier, BUNDLE]
            if args.smoke: command += ['--smoke-test']
            if args.smoke:
                playback_smoke(command, ['xcrun', 'simctl', 'terminate', identifier, BUNDLE])
            else:
                run(command)
        return
    if args.install or args.launch or args.smoke:
        device, udid = physical_device(args.device)
        if args.install:
            install(device, udid)
        if args.launch or args.smoke:
            command = ['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device, '--terminate-existing']
            if args.smoke:
                command += ['--console']
            command += [BUNDLE]
            if args.smoke:
                command += ['--', '--smoke-test']
            if args.smoke:
                playback_smoke(command, lambda: stop_physical_app(device))
            else:
                run(command)


if __name__ == '__main__':
    main()
