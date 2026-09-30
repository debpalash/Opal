#!/usr/bin/env python3
"""Verify cached SDK selection using the production locator and Dockerfile."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('sdk_locator', PROJECT / 'scripts/linux-compat-zig-root.py')
locator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(locator)


class CompatToolchainTests(unittest.TestCase):
    def test_locator_follows_symlinks_and_rejects_wrong_or_incomplete_sdk(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'sdk'
            (sdk / 'lib/std').mkdir(parents=True)
            (sdk / 'lib/std/std.zig').write_text('// fixture')
            compiler = sdk / 'zig'
            compiler.write_text('#!/bin/sh\necho 0.16.0\n')
            compiler.chmod(0o755)
            link = root / 'zig'
            link.symlink_to(compiler)
            self.assertEqual(locator.sdk_root(link), sdk.resolve())
            compiler.write_text('#!/bin/sh\necho 0.15.2\n')
            with self.assertRaisesRegex(ValueError, '0.16.0'):
                locator.sdk_root(link)
            compiler.write_text('#!/bin/sh\necho 0.16.0\n')
            (sdk / 'lib/std/std.zig').unlink()
            with self.assertRaisesRegex(ValueError, 'standard library missing'):
                locator.sdk_root(link)

    @unittest.skipUnless(os.environ.get('OPAL_TEST_DOCKER_CONTEXT'), 'Docker selection regression runs when an isolated test context is supplied')
    def test_production_dockerfile_uses_named_sdk_without_downloading(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'cached-sdk'
            sdk.mkdir()
            (sdk / 'marker').write_text('cached SDK')
            output = root / 'output'
            result = subprocess.run(['docker', '--context', os.environ['OPAL_TEST_DOCKER_CONTEXT'],
                'buildx', 'build', '--file', 'packaging/linux-compat/Dockerfile',
                '--build-context', 'cached_zig=' + str(sdk), '--build-arg', 'OPAL_ZIG_SOURCE=cached_zig',
                '--target', 'zig-toolchain', '--output', 'type=local,dest=' + str(output), '.'],
                cwd=PROJECT, capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((output / 'marker').read_text(), 'cached SDK')


if __name__ == '__main__':
    unittest.main()
