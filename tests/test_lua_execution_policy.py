"""Exercise the shipped Lua prelude with a real interpreter when installed."""
from pathlib import Path
import shutil
import subprocess
import unittest


class LuaPreludeTests(unittest.TestCase):
    def test_native_module_loaders_are_unreachable(self):
        lua = shutil.which('lua') or shutil.which('luajit')
        if not lua:
            self.skipTest('Lua interpreter unavailable; execution approval is covered by Zig policy tests')
        source = (Path(__file__).resolve().parents[1] / 'src/services/plugins.zig').read_text()
        block = source.split('const LUA_SANDBOX_PRELUDE: []const u8 =', 1)[1].split('\n;', 1)[0]
        prelude = '\n'.join(line.lstrip()[2:] for line in block.splitlines() if line.lstrip().startswith('\\\\'))
        probe = '''
assert(package == nil, 'native module loader remains reachable')
assert(debug == nil, 'debug registry remains reachable')
assert(io.open == nil and io.popen == nil and os.execute == nil)
assert(not pcall(require, 'io'), 'require recovered native library')
print('restricted environment passed')
'''
        result = subprocess.run([lua, '-e', prelude + '\n' + probe], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('restricted environment passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
