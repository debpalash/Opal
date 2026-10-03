#!/usr/bin/env python3
"""Production Linux dependency probe checks libraries through pkg-config."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]

@unittest.skipIf(os.name == 'nt', 'requires POSIX shell')
class LinuxDependencyProbe(unittest.TestCase):
    def probe(self, library_present):
        with tempfile.TemporaryDirectory(prefix='opal-dependency-probe-') as directory:
            root = Path(directory)
            for command in ('mpv','curl','python3','pip3','ffmpeg','yt-dlp','zig','gcc','git'):
                file = root / command; file.write_text('#!/bin/sh\nexit 0\n'); file.chmod(0o755)
            ld = root / 'ldconfig'
            ld.write_text('#!/bin/sh\necho "libSDL2-2.0.so.0 libmpv.so.2 libsqlite3.so.0 libtorrent-rasterbar.so.2.0"\n'); ld.chmod(0o755)
            pkg = root / 'pkg-config'
            pkg.write_text('#!/bin/sh\ntest "$*" = "--exists libwebp" || exit 9\nexit '+('0' if library_present else '1')+'\n'); pkg.chmod(0o755)
            env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH'])
            return subprocess.run(['bash',str(PROJECT/'scripts/install-deps.sh'),'--check'],env=env,text=True,capture_output=True,timeout=5)
    def test_decoder_library_is_probed_without_a_fictitious_binary(self):
        result = self.probe(True)
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)
    def test_missing_decoder_development_files_are_reported(self):
        result = self.probe(False)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('libwebp development files',result.stdout)

if __name__ == '__main__': unittest.main()
