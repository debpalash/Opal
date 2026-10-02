#!/usr/bin/env python3
"""Exercise engine imports against pre-PEP585 builtin types (Python 3.8)."""
from pathlib import Path
import os
import subprocess
import sys
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class Python38EngineTests(unittest.TestCase):
    def test_engine_imports_and_proxy_do_not_evaluate_new_builtin_generics(self):
        probe = r'''
from pathlib import Path
import os
import sys
sys.path.insert(0, 'engines')
class LegacyBuiltin:
    pass
import re
re.Pattern = LegacyBuiltin
for filename in ['novaprinter.py', 'helpers.py', 'nova2.py']:
    path = Path('engines') / filename
    ns = dict(__name__='legacy_import', __file__=str(path),
              dict=LegacyBuiltin, list=LegacyBuiltin, set=LegacyBuiltin,
              tuple=LegacyBuiltin, type=LegacyBuiltin)
    exec(compile(path.read_text(), str(path), 'exec'), ns)
    if filename == 'helpers.py':
        os.environ['qbt_socks_proxy'] = 'socks5h://127.0.0.1:1080'
        try:
            ns['enable_socks_proxy'](True)
        finally:
            ns['enable_socks_proxy'](False)
            del os.environ['qbt_socks_proxy']
'''
        result = subprocess.run([os.environ.get('OPAL_TEST_PYTHON38', sys.executable), '-c', probe], cwd=PROJECT,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_all_engine_xml_capabilities_without_python39_indent(self):
        probe = r'''
import sys
sys.path.insert(0, 'engines')
import nova2
import xml.etree.ElementTree as ET
if hasattr(ET, 'indent'):
    del ET.indent
names = nova2.list_engines()
root = ET.fromstring(nova2.get_capabilities(names))
assert {item.tag for item in root} == set(names)
for item in root:
    assert item.find('name').text and item.find('url').text
assert root.find('tokyotoshokan/name').text == 'Tokyo Toshokan'
assert 'anime' in root.find('tokyotoshokan/categories').text.split()
'''
        result = subprocess.run([os.environ.get('OPAL_TEST_PYTHON38', sys.executable), '-c', probe], cwd=PROJECT,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
