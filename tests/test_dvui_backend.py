"""Construct the real build graph without SDL3 available or network fetching."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DvuiBackendTests(unittest.TestCase):
    @unittest.skipUnless(os.name == 'posix', 'isolated package symlinks require POSIX')
    def test_opal_build_graph_does_not_require_unused_sdl3(self):
        cache = ROOT / 'zig-pkg'
        if not shutil.which('zig') or not cache.is_dir():
            self.skipTest('run zig build once to populate zig-pkg')
        with tempfile.TemporaryDirectory(prefix='opal-sdl2-packages-') as directory:
            packages = Path(directory)
            for package in cache.iterdir():
                # SDL2 is uppercase SDL-*; the unused SDL3 package is sdl-*.
                if not package.name.startswith('sdl-'):
                    (packages / package.name).symlink_to(package.resolve(), target_is_directory=True)
            command = ['zig', 'build', '--system', str(packages), '--help']
            # The old graph exposes sdl3: force its package instead of letting
            # --system hide the bug by linking a host SDL3 library. A correctly
            # restricted graph has no sdl3 integration option at all.
            result = subprocess.run(command + ['-fno-sys=sdl3'],
                                    cwd=ROOT, capture_output=True, text=True, timeout=120)
            if "system library name not recognized by build script: 'sdl3'" in result.stderr:
                result = subprocess.run(command, cwd=ROOT, capture_output=True,
                                        text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr[-4000:])
            self.assertIn('test-native-episodes', result.stdout)


if __name__ == '__main__':
    unittest.main()
