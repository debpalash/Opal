"""Device selection and signing policy without touching a real keychain/device."""
import datetime
import hashlib
import importlib.util
import json
import re
from pathlib import Path
import unittest
import tempfile
import sys
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ios_device', ROOT / 'scripts/ios-device.py')
ios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ios)
deps_spec = importlib.util.spec_from_file_location('ios_deps', ROOT / 'scripts/ios-deps.py')
deps = importlib.util.module_from_spec(deps_spec)
deps_spec.loader.exec_module(deps)


class NativeLibraryTests(unittest.TestCase):
    def test_only_physical_arm64_ios_slice_is_selected(self):
        device = {'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64'], 'LibraryIdentifier': 'ios-arm64', 'LibraryPath': 'Player.framework'}
        simulator = {**device, 'LibraryIdentifier': 'ios-arm64_x86_64-simulator', 'SupportedPlatformVariant': 'simulator'}
        desktop = {**device, 'SupportedPlatform': 'macos', 'LibraryIdentifier': 'macos-arm64'}
        self.assertEqual(('ios-arm64', 'Player.framework'), deps.device_slice({'AvailableLibraries': [simulator, desktop, device]}))
        with self.assertRaises(ValueError): deps.device_slice({'AvailableLibraries': [simulator, desktop]})

    def test_framework_paths_cannot_escape_the_device_slice(self):
        with self.assertRaises(ValueError):
            deps.device_slice({'AvailableLibraries': [{'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64'], 'LibraryIdentifier': '../outside', 'LibraryPath': 'Player.framework'}]})

    def test_simulator_uses_its_own_native_binary_variant(self):
        device = {'SupportedPlatform': 'ios', 'SupportedArchitectures': ['arm64'], 'LibraryIdentifier': 'ios-arm64', 'LibraryPath': 'Player.framework'}
        simulator = {**device, 'LibraryIdentifier': 'ios-arm64_x86_64-simulator', 'SupportedPlatformVariant': 'simulator'}
        self.assertEqual(('ios-arm64_x86_64-simulator', 'Player.framework'), deps.platform_slice({'AvailableLibraries': [device, simulator]}, True))
        with self.assertRaises(ValueError): deps.platform_slice({'AvailableLibraries': [device]}, True)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.cert = b'owned-test-development-certificate'
        self.identity = hashlib.sha1(self.cert).hexdigest().upper()
        self.profile = {
            'ExpirationDate': datetime.datetime(2030, 1, 1),
            'ProvisionedDevices': ['owned-phone'],
            'DeveloperCertificates': [self.cert],
            'Entitlements': {'application-identifier': 'TEAM.*', 'get-task-allow': True, 'keychain-access-groups': ['TEAM.*']},
        }

    def match(self):
        return ios.matching_profile(self.profile, 'owned-phone', {self.identity}, datetime.datetime(2026, 1, 1))

    def test_wildcard_development_profile_produces_specific_app_entitlements(self):
        identity, entitlements = self.match()
        self.assertEqual(identity, self.identity)
        self.assertEqual(entitlements['application-identifier'], 'TEAM.' + ios.BUNDLE)
        self.assertEqual(entitlements['keychain-access-groups'], ['TEAM.' + ios.BUNDLE])
        self.assertEqual(self.profile['Entitlements']['application-identifier'], 'TEAM.*')

    def test_different_app_profile_is_not_reused(self):
        self.profile['Entitlements']['application-identifier'] = 'TEAM.com.example.other'
        self.assertIsNone(self.match())

    def test_wrong_device_expired_or_distribution_profile_is_rejected(self):
        for name, value in [('ProvisionedDevices', ['other-phone']), ('ExpirationDate', datetime.datetime(2020, 1, 1))]:
            with patch.dict(self.profile, {name: value}): self.assertIsNone(self.match())
        self.profile['Entitlements']['get-task-allow'] = False
        self.assertIsNone(self.match())

    def test_profile_requires_a_certificate_with_an_available_private_key(self):
        self.assertIsNone(ios.matching_profile(self.profile, 'owned-phone', {'unrelated-identity'}))


class ToolchainTests(unittest.TestCase):
    def test_ios_process_replace_is_unsupported_without_changing_the_toolchain(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'compiler'
            (source / 'std').mkdir(parents=True)
            process = source / 'std/process.zig'
            original = 'pub const can_replace = switch (native_os) {\n .windows, .haiku, .wasi => false,\n else => true,\n};'
            process.write_text(original)
            (source / 'std/Io.zig').write_text('unchanged')
            overlay = ios.prepare_zig_library(source, Path(temp) / 'cache')
            self.assertIn('.ios, .tvos, .visionos, .watchos => false', (overlay / 'std/process.zig').read_text())
            self.assertEqual(process.read_text(), original)
            self.assertTrue((overlay / 'std/Io.zig').is_symlink())
            self.assertEqual(overlay, ios.prepare_zig_library(source, Path(temp) / 'cache'))

    def test_fixed_upstream_toolchain_needs_no_overlay(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)
            (source / 'std').mkdir()
            (source / 'std/process.zig').write_text('pub const can_replace = switch (native_os) { .ios => false, else => true, };')
            self.assertEqual(source, ios.prepare_zig_library(source, source / 'unused'))


class DeviceTests(unittest.TestCase):
    def run_selection(self, devices, requested=None):
        def run(argv, **_):
            path = Path(argv[argv.index('--json-output') + 1])
            path.write_text(json.dumps({'result': {'devices': devices}}))
        with patch.object(ios, 'run', side_effect=run): return ios.physical_device(requested)

    def device(self, ident='phone', reality='physical', paired=True):
        return {'identifier': ident, 'hardwareProperties': {'reality': reality, 'udid': 'udid-' + ident},
                'connectionProperties': {'pairingState': 'paired' if paired else 'unpaired'}, 'deviceProperties': {'name': ident}}

    def test_only_paired_physical_devices_are_eligible(self):
        self.assertEqual(self.run_selection([self.device('sim', 'simulated'), self.device('unpaired', paired=False), self.device()]), ('phone', 'udid-phone'))
        with self.assertRaises(RuntimeError): self.run_selection([self.device('sim', 'simulated')])

    def test_multiple_devices_require_selection_and_simulator_cannot_be_selected(self):
        devices = [self.device('one'), self.device('two'), self.device('sim', 'simulated')]
        with self.assertRaises(RuntimeError): self.run_selection(devices)
        self.assertEqual(self.run_selection(devices, 'udid-two'), ('two', 'udid-two'))
        with self.assertRaises(RuntimeError): self.run_selection(devices, 'sim')


class ReleaseIpaTests(unittest.TestCase):
    # REGRESSION: install() copies the developer's provisioning profile (team,
    # name, device UDIDs) into the build product; a release IPA must not ship it.
    def test_release_ipa_omits_provisioning_profile_and_signature(self):
        import zipfile
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / 'Opal.app'
            (app / '_CodeSignature').mkdir(parents=True)
            (app / '_CodeSignature/CodeResources').write_text('sig')
            (app / 'embedded.mobileprovision').write_text('UDID TEAM')
            (app / 'archived-expanded-entitlements.xcent').write_text('ent')
            (app / 'Opal').write_text('binary'); (app / 'Opal').chmod(0o755)
            (app / 'Info.plist').write_text('plist')
            ipa = ios.package_ipa(app, Path(tmp) / 'out/Opal.ipa', strip=lambda target: None)
            with zipfile.ZipFile(ipa) as z:
                self.assertEqual(['Payload/Opal.app/Info.plist', 'Payload/Opal.app/Opal'], sorted(z.namelist()))
                self.assertTrue((z.getinfo('Payload/Opal.app/Opal').external_attr >> 16) & 0o100)

    # REGRESSION: the release binary's stab symbols carried /Users/<builder>/... paths.
    def test_release_binaries_are_stripped_of_build_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'Opal'
            binary.write_bytes(b'\xcf\xfa\xed\xfe' + b'/Users/builder/src/bridge.m')
            text = Path(tmp) / 'Info.plist'
            text.write_bytes(b'/Users/builder is data, not a symbol table')
            stripped = []
            def strip(target):
                stripped.append(target.name)
                target.write_bytes(b'\xcf\xfa\xed\xfe')
            self.assertEqual(b'\xcf\xfa\xed\xfe', ios.release_bytes(binary, strip))
            self.assertEqual(text.read_bytes(), ios.release_bytes(text, strip))
            self.assertEqual(['Opal'], stripped)
            self.assertIn(b'/Users/builder', binary.read_bytes())  # the build product itself is untouched

    def test_ipa_version_follows_the_app_version(self):
        self.assertEqual(['MARKETING_VERSION=0.9.4', 'CURRENT_PROJECT_VERSION=904'], ios.version_settings('0.9.4'))
        self.assertTrue(re.fullmatch(r'\d+\.\d+\.\d+', ios.app_version()))
        self.assertIn('$(MARKETING_VERSION)', (ROOT / 'mobile/ios/project.yml').read_text())


class PlaybackSmokeTests(unittest.TestCase):
    def test_physical_cleanup_terminates_only_opal_using_the_real_pid_argument(self):
        calls = []
        def run(command, **kwargs):
            calls.append(command)
            if '--json-output' in command:
                Path(command[command.index('--json-output') + 1]).write_text(json.dumps({'result': {'runningProcesses': [
                    {'executable': 'file:///owned/Opal.app/Opal', 'processIdentifier': 123},
                    {'executable': 'file:///owned/Other.app/Other', 'processIdentifier': 456},
                ]}}))
        with patch.object(ios, 'run', side_effect=run): ios.stop_physical_app('owned-phone')
        self.assertEqual(calls[1], ['xcrun', 'devicectl', 'device', 'process', 'terminate', '--device', 'owned-phone', '--pid', '123', '--kill'])
        self.assertEqual(len(calls), 2)

    def smoke(self, program, timeout=2):
        with tempfile.TemporaryDirectory() as temp:
            stopped = Path(temp) / 'stopped'
            stop = [sys.executable, '-c', 'from pathlib import Path; Path(__import__("sys").argv[1]).touch()', str(stopped)]
            try:
                ios.playback_smoke([sys.executable, '-u', '-c', program], stop, timeout)
            finally:
                self.assertTrue(stopped.exists(), 'The test app must be stopped on every exit path')

    def test_requires_shared_player_clock_and_frame_verdict(self):
        self.smoke('print("OPAL_IOS_SHARED_PLAYER_OK time=4.2 texture=1"); __import__("time").sleep(10)')

    def test_frozen_app_is_stopped_and_fails_instead_of_heating_indefinitely(self):
        with self.assertRaisesRegex(RuntimeError, 'timed out'):
            self.smoke('print("OPAL_IOS_UI_READY"); __import__("time").sleep(10)', timeout=0.15)

    def test_failed_playback_or_crash_is_not_a_successful_launch(self):
        with self.assertRaisesRegex(RuntimeError, 'playback failed'):
            self.smoke('print("OPAL_IOS_SHARED_PLAYER_FAILED time=0 texture=0")')
        with self.assertRaisesRegex(RuntimeError, 'playback failed'):
            self.smoke('raise SystemExit(1)')


if __name__ == '__main__': unittest.main()
