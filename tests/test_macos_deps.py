#!/usr/bin/env python3
"""Exercise the production dependency installer with a Homebrew link failure."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


@unittest.skipIf(os.name == 'nt', 'requires POSIX shell')
class MacOSDepsTests(unittest.TestCase):
    def run_helper(self, failure):
        with tempfile.TemporaryDirectory(prefix='opal-brew-regression-') as td:
            root = Path(td)
            (root / 'uname').write_text('#!/bin/sh\necho Darwin\n')
            (root / 'brew').write_text('''#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$TEST_DIR/calls"
case "$*" in
    'install openssl@3')
        if [ ! -f "$TEST_DIR/linked" ]; then
            echo 'Could not symlink bin/openssl: symlink belonging to openssl@1.1' >&2
            test "$TEST_FAILURE" != install || exit 2
            touch "$TEST_DIR/installed"
            exit 1
        fi ;;
    'list --versions openssl@3') test -f "$TEST_DIR/installed" ;;
    'link --overwrite openssl@3')
        test "$TEST_FAILURE" != link || exit 3
        touch "$TEST_DIR/linked" ;;
    'install sqlite'*)
        if [ ! -f "$TEST_DIR/linked" ]; then
            touch "$TEST_DIR/installed"
            echo 'Could not symlink bin/openssl: symlink belonging to openssl@1.1' >&2
            exit 1
        fi
        test "$TEST_FAILURE" != dependency || exit 4 ;;

esac
''')
            for name in ['uname', 'brew']:
                (root / name).chmod(0o755)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       TEST_DIR=str(root), TEST_FAILURE=failure)
            result = subprocess.run(['bash', str(PROJECT / 'scripts/install-macos-deps.sh')],
                                    env=env, text=True, capture_output=True, timeout=10)
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            return result, calls

    def test_orphaned_openssl_11_link_is_repaired(self):
        result, calls = self.run_helper('none')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('link --overwrite openssl@3', calls)
        self.assertEqual(calls.count('install openssl@3\n'), 2)
        self.assertIn('install sqlite', calls)

    def test_real_install_failure_is_not_swallowed(self):
        result, calls = self.run_helper('install')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('install sqlite', calls)

    def test_link_failure_is_not_swallowed(self):
        result, calls = self.run_helper('link')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('install sqlite', calls)

    def test_other_dependency_failure_is_not_swallowed(self):
        result, _ = self.run_helper('dependency')
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
