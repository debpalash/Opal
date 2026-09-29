#!/usr/bin/env python3
"""Regress static bypass helper handling with real Linux ELF binaries."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('compat_elf', PROJECT / 'packaging/linux-compat/elf.py')
elf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elf)
PATCHELF = os.environ.get('OPAL_TEST_PATCHELF') or shutil.which('patchelf')
if os.environ.get('OPAL_REQUIRE_PATCHELF') == '1' and not PATCHELF:
    raise RuntimeError('actual ELF relocation regression requires patchelf')


class CompatElfTests(unittest.TestCase):
    @unittest.skipUnless(PATCHELF, 'patchelf is required in native compatibility CI')
    def test_absolute_private_dependency_is_relocated_and_missing_library_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / 'build-prefix'
            private = root / 'package'
            build.mkdir()
            private.mkdir()
            source = root / 'library.c'
            source.write_text('int value(void) { return 7; }\n')
            library = build / 'libprobe.so'
            main = root / 'main.c'
            main.write_text('extern int value(void); int main(void) { return value() == 7 ? 0 : 1; }\n')
            binary = private / 'app'
            for arguments in [
                ['-shared', '-fPIC', '-Wl,-soname,' + str(library), str(source), '-o', str(library)],
                [str(main), str(library), '-o', str(binary)],
            ]:
                result = subprocess.run([shutil.which('zig') or 'zig', 'cc', '-target', 'x86_64-linux-gnu',
                                         *arguments], capture_output=True, text=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stderr)
            def needed():
                return subprocess.check_output([PATCHELF, '--print-needed', str(binary)], text=True).splitlines()
            self.assertIn(str(library), needed())
            shutil.copy2(library, private / library.name)
            elf.relocate_private_libraries(binary, private, prefix=str(build), patchelf=PATCHELF)
            self.assertIn(library.name, needed())
            self.assertNotIn(str(library), needed())
            self.assertEqual(subprocess.check_output([PATCHELF, '--print-rpath', str(binary)], text=True).strip(), '$ORIGIN')
            (private / library.name).unlink()
            subprocess.run([PATCHELF, '--replace-needed', library.name, str(library), str(binary)], check=True)
            with self.assertRaisesRegex(ValueError, 'private dependency missing'):
                elf.relocate_private_libraries(binary, private, prefix=str(build), patchelf=PATCHELF)

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
