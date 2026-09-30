#!/usr/bin/env python3
"""Compile and run the real libtorrent RAM-streaming regression test locally."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

def main():
    root = Path(__file__).resolve().parents[1]
    cflags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', 'libtorrent-rasterbar'], text=True))
    libs = shlex.split(subprocess.check_output(['pkg-config', '--libs', 'libtorrent-rasterbar'], text=True))
    with tempfile.TemporaryDirectory(prefix='opal-ram-test-') as tmp:
        binary = str(Path(tmp) / 'torrent-memory-test')
        brew = ['-I/opt/homebrew/include'] if Path('/opt/homebrew/include').is_dir() else []
        # Prefer the SDK selected by pkg-config, including isolated regression
        # builds, over the default Homebrew headers and library search path.
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O1', '-pthread', *cflags, *brew,
                        str(root / 'tests/torrent_memory_test.cpp'), '-o', binary, *libs], check=True)
        for mode in ('v1', 'hybrid', 'v2'):
            case = Path(tmp) / mode
            case.mkdir()
            subprocess.run([binary, str(case), mode], check=True, timeout=120)


if __name__ == "__main__":
    main()
