#!/usr/bin/env python3
"""Compile and run the real libtorrent RAM-streaming regression test locally."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

def main():
    root = Path(__file__).resolve().parents[1]
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libtorrent-rasterbar'], text=True))
    with tempfile.TemporaryDirectory(prefix='opal-ram-test-') as tmp:
        binary = str(Path(tmp) / 'torrent-memory-test')
        brew = ['-I/opt/homebrew/include', '-L/opt/homebrew/lib'] if Path('/opt/homebrew/include').is_dir() else []
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-pthread', *brew,
                        str(root / 'tests/torrent_memory_test.cpp'), '-o', binary, *flags], check=True)
        for mode in ('v1', 'hybrid', 'v2'):
            case = Path(tmp) / mode
            case.mkdir()
            subprocess.run([binary, str(case), mode], check=True, timeout=120)


if __name__ == "__main__":
    main()
