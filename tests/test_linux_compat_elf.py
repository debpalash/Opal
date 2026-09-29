#!/usr/bin/env python3
"""Regress static bypass helper handling with real Linux ELF binaries."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('compat_elf', PROJECT / 'packaging/linux-compat/elf.py')
elf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elf)


class CompatElfTests(unittest.TestCase):
    def test_static_helper_and_dynamic_app_are_distinguished(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'probe.c'
            source.write_text('#include <stdio.h>\nint main(void) { return puts("probe") < 0; }\n')
            for name, target, flags, expected in [
                ('static', 'x86_64-linux-musl', ['-static'], False),
                ('dynamic', 'x86_64-linux-gnu', ['-fPIE', '-pie'], True),
            ]:
                binary = root / name
                result = subprocess.run([shutil.which('zig') or 'zig', 'cc', '-target', target,
                                         *flags, str(source), '-o', str(binary)],
                                        capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(elf.has_dynamic_segment(binary), expected)

    def test_truncated_or_unknown_elf_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'invalid'
            for data in [b'not ELF', b'\x7fELF\x02\x01', b'\x7fELF\x01\x01' + b'\0' * 58]:
                binary.write_bytes(data)
                with self.assertRaises(ValueError):
                    elf.has_dynamic_segment(binary)


if __name__ == '__main__':
    unittest.main()
