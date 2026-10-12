"""Opal's build graph must not pull in DVUI's unused SDL3 backend.

DVUI only reaches its SDL3 package through ``linkSdl3()``, which first
declares the ``sdl3`` system integration option and only then calls
``b.lazyDependency("sdl3")``. So if ``sdl3`` is absent from the
"Available System Integrations" list of ``zig build --help``, the configured
graph never asked for the SDL3 package. Dropping ``.backend = .sdl2`` from
build.zig makes ``sdl3`` appear there, so the check is not vacuous.

This used to run ``zig build --system <pkgdir>`` with the SDL3 package left
out. Zig 0.16 spins forever in package resolution under ``--system`` whenever a
system package has a relative ``.path`` dependency (ghostty has several), so
that probe hung regardless of SDL3.
"""
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def system_integrations(help_text):
    """Names listed under 'Available System Integrations:' in zig build --help."""
    lines = help_text.splitlines()
    for i, line in enumerate(lines):
        if line.strip().startswith('Available System Integrations:'):
            names = []
            for row in lines[i + 1:]:
                match = re.match(r'^\s{4}(\S+)\s+(yes|no)\s*$', row)
                if not match:
                    break
                names.append(match.group(1))
            return names
    return []


class DvuiBackendTests(unittest.TestCase):
    def test_opal_build_graph_does_not_require_unused_sdl3(self):
        if not shutil.which('zig') or not (ROOT / 'zig-pkg').is_dir():
            self.skipTest('run zig build once to populate zig-pkg')
        # Generous timeout only covers a cold build-runner compile; a warm
        # cache answers in well under a second.
        result = subprocess.run(['zig', 'build', '--help'], cwd=ROOT,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr[-4000:])
        self.assertIn('test-native-episodes', result.stdout)
        names = system_integrations(result.stdout)
        self.assertIn('sdl2', names, 'help output format changed; parser found: %r' % names)
        self.assertNotIn('sdl3', names)

    def test_parser_detects_sdl3(self):
        sample = ('  Available System Integrations:                Enabled:\n'
                  '    sdl2                                        no\n'
                  '    sdl3                                        no\n'
                  '\n')
        self.assertEqual(system_integrations(sample), ['sdl2', 'sdl3'])


if __name__ == '__main__':
    unittest.main()
