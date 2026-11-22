#!/usr/bin/env python3
"""Compile and run the seek-deadline / transfer-facts FFI test against a real loopback seed."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    cflags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'libtorrent-rasterbar'], text=True))
    libs = shlex.split(subprocess.check_output(['pkg-config', '--libs', 'libtorrent-rasterbar'], text=True))
    with tempfile.TemporaryDirectory(prefix='opal-deadline-test-') as tmp:
        binary = str(Path(tmp) / 'torrent-deadline-test')
        brew = ['-I/opt/homebrew/include'] if Path('/opt/homebrew/include').is_dir() else []
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-pthread', *cflags, *brew,
                        str(root / 'tests/torrent_deadline_test.cpp'), '-o', binary, *libs], check=True)
        case = Path(tmp) / 'case'
        case.mkdir()
        subprocess.run([binary, str(case)], check=True, timeout=120)


if __name__ == "__main__":
    main()
