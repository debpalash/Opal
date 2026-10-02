#!/usr/bin/env python3
"""Check the actual compatibility manifest preserves its complete file tree."""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
NFPM = os.environ.get('OPAL_TEST_NFPM') or shutil.which('nfpm')


@unittest.skipUnless(NFPM, 'nfpm is required; the compatibility CI job supplies it')
class CompatManifestTests(unittest.TestCase):
    def test_launchers_and_nested_resources_keep_distinct_paths(self):
        payload = {
            'bin/opal': b'system launcher',
            'lib/opal/opal': b'private launcher',
            'lib/opal/engines/nova2.py': b'engine resource',
            'share/doc/opal/LICENSE': b'license',
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, data in payload.items():
                path = root / 'compat-artifacts/compat-root/usr' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            package = root / 'opal.deb'
            result = subprocess.run([NFPM, 'package', '-f', str(PROJECT / 'packaging/linux-compat/nfpm.yaml'),
                                     '-p', 'deb', '-t', str(package)], cwd=root,
                                    env=dict(os.environ, VERSION='0.8.8'), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            members = subprocess.check_output(['ar', 't', str(package)], text=True).splitlines()
            member = next(name for name in members if name.startswith('data.tar'))
            data = subprocess.check_output(['ar', 'p', str(package), member])
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                files = {item.name.lstrip('./'): item for item in archive if item.isfile()}
                for name, expected in payload.items():
                    self.assertEqual(archive.extractfile(files['usr/' + name]).read(), expected)


if __name__ == '__main__':
    unittest.main()
