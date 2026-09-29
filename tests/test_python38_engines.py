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
for filename in ['helpers.py', 'nova2.py']:
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
        result = subprocess.run([sys.executable, '-c', probe], cwd=PROJECT,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
