"""Opal-owned Jackett runner. Stdout is a private JSON event pipe, not a log.

Official self-contained binaries stay in Opal's data directory. The parent
contains this process and its child in one process group / Windows job.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

VERSION = "v0.24.3003"
ASSETS = {
    ("Darwin", "arm64"): ("macOSARM64.tar.gz", "0e7c81ce2e8cb57913b211d2ec8961c9d86a8f3bbbab5c8d47cc1dee837f8644"),
    ("Darwin", "x86_64"): ("macOS.tar.gz", "1414dd514546d82570635e2673ce9593230be3172e735dd441e62648a35ab6aa"),
    ("Linux", "x86_64"): ("LinuxAMDx64.tar.gz", "0073570ca568d8cb2f6c14931e319262aa37f61c8f0754f79c896e31eea1040f"),
    ("Linux", "aarch64"): ("LinuxARM64.tar.gz", "b407a1ca28001edefb6e87f15fe36f394f654be058507871bd5ff5233958e172"),
    ("Windows", "amd64"): ("Windows.zip", "c2d6072b2b1f23256d5bdd2298366aee5566237d1592e0025e17ebbfdc9026fd"),
}
MAX_ARCHIVE = 100 * 1024 * 1024
MAX_EXTRACTED = 400 * 1024 * 1024


def event(kind, **data):
    print(json.dumps(dict(event=kind, **data)), flush=True)


def asset_for(system=None, machine=None):
    system = system or platform.system()
    machine = (machine or platform.machine()).lower()
    if machine == 'arm64' and system == 'Linux':
        machine = 'aarch64'
    return ASSETS[(system, machine)]


def download(url, destination, digest):
    request = urllib.request.Request(url, headers={'User-Agent': 'Opal-Jackett'})
    sha = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(request, timeout=30) as response, open(destination, 'wb') as out:
        if not response.geturl().startswith('https://'):
            raise ValueError('Insecure download')
        while True:
            block = response.read(256 * 1024)
            if not block:
                break
            total += len(block)
            if total > MAX_ARCHIVE:
                raise ValueError('Archive too large')
            sha.update(block)
            out.write(block)
    if sha.hexdigest() != digest:
        raise ValueError('Release checksum mismatch')


def extract(archive, destination):
    """Only regular files/directories below the root; never links or devices."""
    total = 0
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                total += info.file_size
                if total > MAX_EXTRACTED or (info.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('Unsafe archive')
                target = safe_target(destination, info.filename)
                if info.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with z.open(info) as src, open(target, 'wb') as out:
                        copy_file(src, out)
    else:
        with tarfile.open(archive, 'r:gz') as tar:
            for info in tar:
                total += info.size
                if total > MAX_EXTRACTED or not (info.isdir() or info.isfile()):
                    raise ValueError('Unsafe archive')
                target = safe_target(destination, info.name)
                if info.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(info) as src, open(target, 'wb') as out:
                        copy_file(src, out)
                    target.chmod(info.mode & 0o755)


def safe_target(root, name):
    target = (root / name).resolve()
    if '\\' in name or ':' in name or not target.is_relative_to(root.resolve()):
        raise ValueError('Archive path traversal')
    return target


def copy_file(src, out):
    while True:
        block = src.read(256 * 1024)
        if not block:
            break
        out.write(block)


def ensure_binary(root):
    filename, digest = asset_for()
    directory = root / VERSION
    executable = 'JackettConsole.exe' if platform.system() == 'Windows' else 'jackett'
    binary = directory / 'Jackett' / executable
    if binary.is_file():
        return binary
    event('status', message='Downloading Jackett (~50 MB)…')
    with tempfile.TemporaryDirectory(prefix='.install-', dir=root) as temp:
        temp = Path(temp)
        archive = temp / filename
        download(f'https://github.com/Jackett/Jackett/releases/download/{VERSION}/Jackett.Binaries.{filename}', archive, digest)
        stage = temp / 'stage'
        stage.mkdir()
        extract(archive, stage)
        if not (stage / 'Jackett' / executable).is_file():
            raise ValueError('Release executable missing')
        stage.rename(directory)
    return binary


def lock_root(root):
    handle = open(root / '.owner.lock', 'a+b')
    if os.name == 'nt':
        import msvcrt
        handle.seek(0)
        handle.write(b'0')
        handle.flush()
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return handle


def prepare_config(root):
    data = root / 'data'
    data.mkdir(exist_ok=True)
    path = data / 'ServerConfig.json'
    config = json.loads(path.read_text()) if path.exists() else {}
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    key = config.get('APIKey') or secrets.token_hex(16)
    config.update(Port=port, LocalBindAddress='127.0.0.1', AllowExternal=False,
                  AllowCORS=False, APIKey=key, UpdateDisabled=True)
    temp = path.with_suffix('.tmp')
    with open(temp, 'w', encoding='utf-8') as out:
        json.dump(config, out)
    temp.chmod(0o600)
    temp.replace(path)
    return data, f'http://127.0.0.1:{port}', key


def serve(root):
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.umask(0o077)
    ownership = lock_root(root)
    binary = ensure_binary(root)
    data, base, key = prepare_config(root)
    event('status', message='Starting Jackett…')
    # Keep Jackett in the parent's contained process group / job.
    child = subprocess.Popen([str(binary), '--DataFolder', str(data), '--ListenPrivate', '--NoUpdates', '--NoRestart'],
                             cwd=binary.parent, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 40
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        while child.poll() is None and time.monotonic() < deadline:
            try:
                with opener.open(base + '/api/v2.0/indexers/all/results/torznab/api?t=indexers&configured=true&apikey=' + key, timeout=1) as response:
                    catalog = ET.fromstring(response.read(256 * 1024))
                    if catalog.tag != 'indexers':
                        raise ValueError('Invalid catalog')
                event('ready', base=base, apikey=key)
                if child.wait() != 0:
                    raise RuntimeError('Jackett exited')
                return
            except (OSError, ValueError, ET.ParseError):
                time.sleep(.2)
        raise RuntimeError('Jackett did not start')
    finally:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        ownership.close()


if __name__ == '__main__':
    def stop(*_):
        raise SystemExit(0)
    # Install cancellation must unwind the temporary archive directory too.
    signal.signal(signal.SIGTERM, stop)
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    try:
        serve(args.root.resolve())
    except Exception:
        # Never expose tracker credentials or raw request URLs in error output.
        event('error', message='Jackett failed. Check connectivity and retry.')
        sys.exit(1)
