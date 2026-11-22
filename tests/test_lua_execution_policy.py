"""Exercise the shipped Lua prelude with a real interpreter when installed."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PURE = Path(__file__).resolve().parents[1] / 'src/services/plugin_permissions_pure.zig'


def _zig_multiline(source, name):
    block = source.split('pub const %s: []const u8 =' % name, 1)[1].split('\n;', 1)[0]
    return '\n'.join(line.lstrip()[2:] for line in block.splitlines() if line.lstrip().startswith('\\\\')) + '\n'


def build_prelude(plugin_dir, modules):
    """Mirror plugin_permissions_pure.buildPrelude (format pinned by its Zig test)."""
    source = PURE.read_text()
    allow = ''.join('["%s"]=true,' % m for m in sorted(set(modules)))
    return (_zig_multiline(source, 'PRELUDE_HEAD')
            + 'local __dir=[==[%s]==]\nlocal __allow={%s}\n' % (plugin_dir, allow)
            + _zig_multiline(source, 'PRELUDE_TAIL'))


def run_lua(prelude, probe):
    lua = shutil.which('lua') or shutil.which('luajit')
    return subprocess.run([lua, '-e', prelude + '\n' + probe], capture_output=True, text=True, timeout=5)


@unittest.skipUnless(shutil.which('lua') or shutil.which('luajit'), 'Lua interpreter unavailable')
class LuaPreludeTests(unittest.TestCase):
    def test_native_module_loaders_are_unreachable(self):
        with tempfile.TemporaryDirectory() as d:
            probe = '''
assert(package == nil, 'native module loader remains reachable')
assert(debug == nil, 'debug registry remains reachable')
assert(io.open == nil and io.popen == nil and os.execute == nil)
assert(not pcall(require, 'io'), 'require recovered native library')
assert(not pcall(require, 'debug'), 'require recovered debug library')
print('restricted environment passed')
'''
            result = run_lua(build_prelude(d, []), probe)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('restricted environment passed', result.stdout)

    def test_allow_list_admits_only_listed_plugin_modules(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, 'helper.lua').write_text('return {answer = 42, exec = os.execute}\n')
            Path(d, 'other.lua').write_text('return {}\n')
            Path(d, 'lib').mkdir()
            Path(d, 'lib', 'util.lua').write_text('return {nested = true}\n')
            probe = '''
local h = require('helper')
assert(h.answer == 42, 'allow-listed plugin module did not load')
assert(h.exec == nil, 'allow-listed module escaped the sanitized globals')
assert(require('lib.util').nested, 'dotted module did not resolve inside the plugin dir')
local ok, err = pcall(require, 'other')
assert(not ok and tostring(err):find('require denied'), 'unlisted module was not denied')
assert(not pcall(require, 'socket'), 'unlisted system module was not denied')
print('allow-list passed')
'''
            result = run_lua(build_prelude(d, ['helper', 'lib.util']), probe)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('allow-list passed', result.stdout)

    def test_allow_listed_name_cannot_load_native_code(self):
        with tempfile.TemporaryDirectory() as d:
            # No Lua file exists, and the C searchers are gone: listing a name
            # that only a native library could satisfy must still fail.
            result = run_lua(build_prelude(d, ['lfs']), 'assert(not pcall(require, "lfs")) print("native denied")')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('native denied', result.stdout)


if __name__ == '__main__':
    unittest.main()
