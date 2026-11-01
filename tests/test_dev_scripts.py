"""Exercise the real dev scripts with isolated bundles and fake system tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DevScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'])
        for name in ('install-app.sh', 'stop-dev.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)

    def tool(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/bash\n' + body + '\n')
        p.chmod(0o755)

    def test_install_consumes_option_values_and_installs_to_requested_destination(self):
        src = self.root / 'dist/Opal.app'
        src.mkdir(parents=True)
        (src / 'marker').write_text('release')
        (self.root / 'scripts/stop-dev.sh').write_text('#!/bin/bash\nexit 0\n')
        self.tool('ditto', 'cp -R "$1" "$2"')
        self.tool('codesign', 'exit 0')
        self.tool('xattr', 'exit 0')
        self.tool('defaults', 'echo test-version')
        for args in (
            ['--dest', str(self.root / 'split'), '--sign', 'Test Identity'],
            ['--skip-build', '--dest', str(self.root / 'mixed'), '--sign', 'Test Identity'],
            ['--dest=' + str(self.root / 'equals'), '--sign=Test Identity'],
        ):
            result = subprocess.run(
                ['bash', str(self.root / 'scripts/install-app.sh'), *args,
                 '--skip-build', '--no-launch'], env=self.env,
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ('split', 'mixed', 'equals'):
            self.assertEqual((self.root / name / 'Opal.app/marker').read_text(), 'release')

    def test_failed_copy_preserves_installed_app(self):
        src = self.root / 'dist/Opal.app'
        src.mkdir(parents=True)
        dest = self.root / 'installed'
        old = dest / 'Opal.app'
        old.mkdir(parents=True)
        (old / 'marker').write_text('working version')
        self.tool('ditto', 'exit 1')
        result = subprocess.run(
            ['bash', str(self.root / 'scripts/install-app.sh'), '--skip-build',
             '--no-launch', '--dest', str(dest)], env=self.env,
            capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((old / 'marker').read_text(), 'working version')
        self.assertEqual(list(dest.glob('.opal-install.*')), [])

    def test_install_rejects_source_as_destination(self):
        src = self.root / 'dist/Opal.app'
        src.mkdir(parents=True)
        (src / 'marker').write_text('source')
        result = subprocess.run(
            ['bash', str(self.root / 'scripts/install-app.sh'), '--skip-build',
             '--no-launch', '--dest', str(src.parent)], env=self.env,
            capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((src / 'marker').read_text(), 'source')

    def test_stop_matches_actual_proxy_argument_order(self):
        # The fake pgrep matches its supplied regex against the production argv.
        self.env['REVIEW_PROXY'] = '/app/zig-bypassdpi --port 8881 --listen 127.0.0.1 --mode sni'
        self.env['REVIEW_ALIVE'] = str(self.root / 'alive')
        self.env['REVIEW_KILLED'] = str(self.root / 'killed')
        Path(self.env['REVIEW_ALIVE']).touch()
        self.tool('pgrep', '''[ -f "$REVIEW_ALIVE" ] || exit 1
printf '%s\\n' "$REVIEW_PROXY" | /usr/bin/grep -Eq -- "$2"''')
        self.tool('pkill', '''printf '%s\\n' "$*" >> "$REVIEW_KILLED"
rm "$REVIEW_ALIVE"''')
        self.tool('sleep', 'exit 0')
        result = subprocess.run(['bash', str(self.root / 'scripts/stop-dev.sh'), '--force'],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(Path(self.env['REVIEW_ALIVE']).exists(), 'orphan proxy survived')
        self.assertIn('zig-bypassdpi', Path(self.env['REVIEW_KILLED']).read_text())


if __name__ == '__main__':
    unittest.main()
