#!/usr/bin/env python3
"""Verify the actual GUI package and both installer layouts on Ubuntu 20.04."""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request
import urllib.parse
import urllib.error
from elf import has_dynamic_segment

assert subprocess.check_output(['getconf', 'GNU_LIBC_VERSION'], text=True).strip() == 'glibc ' + os.environ.get('EXPECTED_GLIBC', '2.31')
for binary in Path('/usr/lib/opal').iterdir():
    if binary.is_file() and binary.read_bytes()[:4] == b'\x7fELF' and has_dynamic_segment(binary):
        linked = subprocess.run(['ldd', str(binary)], text=True, capture_output=True)
        assert linked.returncode == 0 and 'not found' not in linked.stdout, (binary, linked.stdout, linked.stderr)
# Import the actual packaged search engines on the distribution's Python
# (3.8 on Focal), then exercise the app's offline thread-pool seam.
engines = subprocess.check_output(['python3', '/usr/lib/opal/engines/nova2.py', '--capabilities', '--names'], text=True)
assert 'nekobt' in engines and 'shanaproject' in engines, 'packaged torrent engines failed to import'
pool = subprocess.check_output(['python3', '/usr/lib/opal/engines/nova2.py', '--timeout=2', '--pool-selftest'], text=True)
assert 'NOVA2_APP_POOL_OK' in pool, 'packaged torrent dispatcher failed'
subprocess.run(['python3', '/usr/lib/opal/scripts/camoufox_bridge.py', '--selftest'], check=True)
# The software build must retain AV1 decoding as well as native H.264/HEVC.
decoders = subprocess.check_output(['/usr/lib/opal/ffmpeg', '-hide_banner', '-decoders'], text=True)
assert 'libdav1d' in decoders, 'AV1 software decoder missing'
# Exercise a decoder in the privately shipped FFmpeg, with a real output file.
subprocess.run(['/usr/lib/opal/ffmpeg', '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'testsrc=size=96x96:rate=10', '-t', '30',
                '-c:v', 'mpeg4', '-y', '/tmp/sample.mp4'], check=True)
subprocess.run(['/usr/lib/opal/ffmpeg', '-hide_banner', '-loglevel', 'error',
                '-i', '/tmp/sample.mp4', '-frames:v', '1', '-f', 'null', '-'], check=True)


def launch(command, config):
    config.mkdir(parents=True)
    (config / 'opal').mkdir()
    (config / 'opal/config.tsv').write_text('web_remote=1\n')
    env = dict(os.environ, XDG_CONFIG_HOME=str(config), XDG_CACHE_HOME=str(config / 'cache'),
               SDL_VIDEODRIVER='x11', LIBGL_ALWAYS_SOFTWARE='1')
    log = config / 'launch.log'
    with log.open('w') as output:
        app = subprocess.Popen(['xvfb-run', '-a', command, '/tmp/sample.mp4'],
                               env=env, stdout=output, stderr=subprocess.STDOUT,
                               start_new_session=True)
        try:
            for _ in range(60):
                assert app.poll() is None, log.read_text()
                try:
                    with urllib.request.urlopen('http://127.0.0.1:41595/health', timeout=1) as response:
                        assert response.status == 200
                        json.load(response)
                    with urllib.request.urlopen('http://127.0.0.1:41595/', timeout=1) as response:
                        assert b'<html' in response.read().lower(), 'packaged Web UI missing'
                    break
                except (OSError, ValueError):
                    time.sleep(.5)
            else:
                raise AssertionError('GUI did not initialize API: ' + log.read_text())
            client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
            setup = (config / 'opal/setup.token').read_text().strip()
            payload = urllib.parse.urlencode({'username': 'compat-test', 'password': 'package-test-password'}).encode()
            request = urllib.request.Request('http://127.0.0.1:41595/api/auth/register', data=payload,
                headers={'X-Opal-Setup-Token': setup, 'Origin': 'http://127.0.0.1:41595',
                         'Content-Type': 'application/x-www-form-urlencoded'})
            with client.open(request, timeout=10) as response:
                assert json.load(response) == {'ok': True}, 'account creation failed'
            assert not (config / 'opal/setup.token').exists(), 'setup capability was not consumed'
            # The authenticated status must report the actual packaged player
            # opening the video, rather than only a responsive HTTP listener.
            for _ in range(20):
                with client.open('http://127.0.0.1:41595/api/status', timeout=2) as response:
                    status = json.load(response)
                if status.get('dur', 0) > 0 and status.get('active'):
                    assert not status.get('error'), 'media playback error'
                    break
                time.sleep(.5)
            else:
                raise AssertionError('packaged player did not open the sample video')
            try:
                urllib.request.urlopen('http://127.0.0.1:41595/api/status', timeout=2)
            except urllib.error.HTTPError as error:
                assert error.code == 401
            else:
                raise AssertionError('protected API accepted an unauthenticated request')
            time.sleep(3)
            assert app.poll() is None, log.read_text()
        finally:
            import signal
            os.killpg(app.pid, signal.SIGTERM)
            app.wait(timeout=10)
    print(f'PASS: {command}: GUI + account + protected API + video + resources')


launch('/usr/bin/opal', Path('/tmp/system-config'))
# Fake only the network download, preserving real dpkg-deb, checksum validation,
# runtime detection, extraction and installed launchers from scripts/install.sh.
version = os.environ['VERSION']
asset = f'opal_{version}_compat_amd64.deb'
fixture = Path('/tmp/release-fixture')
fixture.mkdir()
(fixture / 'SHA256SUMS.txt').write_text(hashlib.sha256(Path('/tmp/opal.deb').read_bytes()).hexdigest() + '  ' + asset + '\n')
(fixture / 'curl').write_text('''#!/bin/sh
out=''; url=''
while [ "$#" -gt 0 ]; do
    case "$1" in -o) shift; out="$1" ;; http*) url="$1" ;; esac
    shift
done
case "$url" in
    */SHA256SUMS.txt) cp /tmp/release-fixture/SHA256SUMS.txt "$out" ;;
    */''' + asset + ''') cp /tmp/opal.deb "$out" ;;
    *) echo "unexpected release asset: $url" >&2; exit 1 ;;
esac
''')
(fixture / 'curl').chmod(0o755)
env = dict(os.environ, PATH=str(fixture) + ':' + os.environ['PATH'], OPAL_PREFIX='/tmp/local-opal',
           OPAL_VERSION='v' + version, OPAL_SYSTEM='0', XDG_CONFIG_HOME='/tmp/installer-config')
subprocess.run(['sh', '/tmp/install.sh'], env=env, check=True)
launch('/tmp/local-opal/bin/opal', Path('/tmp/local-config'))
print('PASS: Ubuntu 20.04 compatible package, media decoder, system + user-local installs')
