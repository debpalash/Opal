#!/usr/bin/env python3
"""Run the real installer with isolated release tools and Linux runtime probes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name != 'nt' and shutil.which('sh'), 'requires a POSIX shell')
class LinuxRuntimeTests(unittest.TestCase):
    def run_installer(self, libc, system='1', command='install', probe_status=0, version='0.8.7'):
        with tempfile.TemporaryDirectory(prefix='opal-linux-runtime-') as directory:
            root = Path(directory)
            fakebin = root / 'tools'
            fakebin.mkdir()
            prefix = root / 'prefix'
            (prefix / 'bin').mkdir(parents=True)
            launcher = prefix / 'bin/opal'
            launcher.write_text('existing installation\n')
            config = root / 'config/opal'
            config.mkdir(parents=True)
            receipt = config / '.install-method'
            receipt.write_text(f'local-prefix:{prefix} v0.8.6\n')

            def fake(name, body):
                path = fakebin / name
                path.write_text('#!/bin/sh\nset -eu\n' + body)
                path.chmod(0o755)

            fake('uname', 'case "$1" in -m) echo x86_64 ;; *) echo Linux ;; esac\n')
            fake('getconf', 'printf "%s\\n" "$TEST_LIBC"\nexit "$TEST_PROBE_STATUS"\n')
            fake('id', 'echo 0\n')
            fake('sha256sum', 'printf "testhash  %s\\n" "$1"\n')
            fake('curl', r'''
out=''; url=''
while [ "$#" -gt 0 ]; do
    case "$1" in -o) shift; out="$1" ;; http*) url="$1" ;; esac
    shift
done
case "$url" in
    */SHA256SUMS.txt)
        printf 'testhash  opal_%s_amd64.deb\n' "$TEST_VERSION" > "$out"
        if [ "$TEST_VERSION" = 0.8.8 ]; then printf 'testhash  opal_%s_compat_amd64.deb\n' "$TEST_VERSION" >> "$out"; fi ;;

    */releases/latest|*/releases\?*) echo '{"tag_name":"v0.8.7"}' ;;
    *) touch "$TEST_ROOT/downloaded"; echo "$url" >> "$TEST_ROOT/assets"; : > "$out" ;;
esac
''')
            fake('dpkg-deb', r'''
dest="$3"
mkdir -p "$dest/usr/bin" "$dest/usr/lib/opal/engines"
printf '#!/bin/sh\nexit 99\n' > "$dest/usr/bin/opal"
chmod +x "$dest/usr/bin/opal"
printf '#!/bin/sh\nexit 0\n' > "$dest/usr/lib/opal/opal"
chmod +x "$dest/usr/lib/opal/opal"
printf '# fixture\n' > "$dest/usr/lib/opal/engines/nova2.py"
''')
            fake('apt-get', 'touch "$TEST_ROOT/apt-called"\n')
            fake('sudo', 'touch "$TEST_ROOT/sudo-called"\nexit 99\n')
            env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ['PATH'],
                       OPAL_VERSION='v' + version, OPAL_SYSTEM=system,
                       OPAL_PREFIX=str(prefix), XDG_CONFIG_HOME=str(root / 'config'),
                       TEST_ROOT=str(root), TEST_VERSION=version, TEST_LIBC=libc, TEST_PROBE_STATUS=str(probe_status))
            result = subprocess.run(['sh', str(PROJECT / 'scripts/install.sh'), command],
                                    env=env, capture_output=True, text=True, timeout=10)
            launched = None
            if result.returncode == 0 and system == '0' and command == 'install':
                launched = subprocess.run([str(launcher)], env=env).returncode
            return result, {
                'launch_status': launched,
                'downloaded': (root / 'downloaded').exists(),
                'assets': (root / 'assets').read_text() if (root / 'assets').exists() else '',
                'apt_called': (root / 'apt-called').exists(),
                'sudo_called': (root / 'sudo-called').exists(),
                'launcher': launcher.read_text() if launcher.exists() else None,
                'receipt': receipt.read_text() if receipt.exists() else None,
            }

    def test_issue_100_rejects_old_hosts_before_download_or_package_install(self):
        for version in ['2.9', '2.31', '2.35', '2.36', '2.37']:
            for system in ['0', '1']:
                with self.subTest(version=version, system=system):
                    result, state = self.run_installer('glibc ' + version, system)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('detected glibc ' + version, result.stderr)
                    self.assertIn('glibc 2.31' if version == '2.9' else 'glibc 2.38', result.stderr)
                    self.assertFalse(state['downloaded'])
                    self.assertFalse(state['apt_called'])
                    self.assertFalse(state['sudo_called'])
                    self.assertEqual(state['launcher'], 'existing installation\n')
                    self.assertTrue(state['receipt'].endswith('v0.8.6\n'))

    def test_issue_100_selects_verified_compat_package_on_ubuntu_20(self):
        for libc in ['2.31', '2.35', '2.36', '2.37']:
            for system in ['0', '1']:
                with self.subTest(libc=libc, system=system):
                    result, state = self.run_installer('glibc ' + libc, system=system, version='0.8.8')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('opal_0.8.8_compat_amd64.deb', state['assets'])
                    self.assertEqual(state['apt_called'], system == '1')
                    if system == '0':
                        self.assertEqual(state['launch_status'], 0)
                    self.assertTrue(state['receipt'].endswith(' v0.8.8\n'))

    def test_new_release_keeps_modern_package_on_modern_host(self):
        result, state = self.run_installer('glibc 2.39', version='0.8.8')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('opal_0.8.8_amd64.deb', state['assets'])
        self.assertNotIn('_compat_', state['assets'])

    def test_supported_runtime_versions_reach_the_system_install(self):
        for version in ['2.38', '2.38.1', '2.39', '2.100', '3.0']:
            with self.subTest(version=version):
                result, state = self.run_installer('glibc ' + version)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(state['apt_called'])
                self.assertEqual(state['receipt'], 'deb v0.8.7\n')

    def test_unknown_runtime_and_failed_probe_do_not_install(self):
        for libc, status in [('musl 1.2.5', 0), ('glibc unknown', 0), ('glibc 2', 0),
                             ('glibc 2:38.0', 0), ('glibc 2.38bad', 0), ('', 1)]:
            with self.subTest(libc=libc, status=status):
                result, state = self.run_installer(libc, probe_status=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(state['downloaded'])
                self.assertFalse(state['apt_called'])

    def test_older_runtime_can_uninstall_without_compatibility_probe(self):
        result, state = self.run_installer('glibc 2.31', command='uninstall')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(state['launcher'])
        self.assertIsNone(state['receipt'])

    def test_older_runtime_can_list_versions(self):
        result, state = self.run_installer('glibc 2.31', command='list-versions')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('v0.8.7', result.stdout)
        self.assertFalse(state['downloaded'])


if __name__ == '__main__':
    unittest.main()
