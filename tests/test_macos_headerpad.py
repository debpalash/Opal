#!/usr/bin/env python3
"""Use the shipped FFmpeg link flags to test a Mach-O install-name rewrite."""
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang') and shutil.which('install_name_tool'),
                     'requires macOS Mach-O tools')
class HeaderPaddingTests(unittest.TestCase):
    def test_ffmpeg_library_can_expand_bundled_dependency_paths(self):
        script = (PROJECT / 'scripts/install-macos-ffmpeg.sh').read_text()
        match = re.search(r'--extra-ldflags="([^"]+)"', script)
        flags = shlex.split(match.group(1)) if match else []
        with tempfile.TemporaryDirectory(prefix='opal-headerpad-') as td:
            root = Path(td)
            (root / 'dep.c').write_text('int dependency(void) { return 1; }\n')
            (root / 'library.c').write_text('extern int dependency(void); int exported(void) { return dependency(); }\n')
            dep = root / 'libdep.dylib'
            library = root / 'libmedia.dylib'
            original = '/short/libdep.dylib'
            rewritten = '@executable_path/../Frameworks/' + 'x' * 512 + '.dylib'
            subprocess.run(['clang', '-dynamiclib', str(root / 'dep.c'), '-o', str(dep),
                            '-Wl,-install_name,' + original], check=True, capture_output=True)
            subprocess.run(['clang', '-dynamiclib', str(root / 'library.c'), str(dep),
                            '-o', str(library), *flags], check=True, capture_output=True)
            result = subprocess.run(['install_name_tool', '-change', original, rewritten, str(library)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            imports = subprocess.check_output(['otool', '-L', str(library)], text=True)
            self.assertIn(rewritten, imports)


if __name__ == '__main__':
    unittest.main()
