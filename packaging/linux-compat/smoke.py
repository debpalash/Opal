#!/usr/bin/env python3
"""Verify the actual GUI package and both installer layouts on Ubuntu 20.04."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

assert subprocess.check_output(['getconf', 'GNU_LIBC_VERSION'], text=True).strip() == 'glibc 2.31'
for binary in Path('/usr/lib/opal').iterdir():
    if binary.is_file() and binary.read_bytes()[:4] == b'\x7fELF':
        linked = subprocess.run(['ldd', str(binary)], text=True, capture_output=True)
        assert linked.returncode == 0 and 'not found' not in linked.stdout, (binary, linked.stdout, linked.stderr)
# Exercise a decoder in the privately shipped FFmpeg, with a real output file.
subprocess.run(['/usr/lib/opal/ffmpeg', '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'testsrc=size=96x96:rate=10', '-t', '2',
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
            time.sleep(3)
            assert app.poll() is None, log.read_text()
        finally:
            import signal
            os.killpg(app.pid, signal.SIGTERM)
            app.wait(timeout=10)
    print(f'PASS: {command}: GUI + API + resource serving')


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
