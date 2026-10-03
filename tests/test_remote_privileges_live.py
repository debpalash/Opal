#!/usr/bin/env python3
"""Isolated route-level privilege/transport regression tests; requires headless binary.
Run: python3 tests/test_remote_privileges_live.py --binary zig-out/bin/opal --port 41987
"""
import os
from pathlib import Path
import sys
import unittest
import test_setup_token_live as harness


class RemotePrivilegeTests(unittest.TestCase):
    def setUp(self):
        if harness.BINARY is None:
            self.skipTest('pass --binary or OPAL_HEADLESS_BIN')
        self.opal = harness.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)

    def call(self, method, path, credential=None, form=None, headers=()):
        auth = () if credential is None else (("Cookie", credential),)
        return harness.request(method, path, host=self.opal.loopback_authority,
                               form=form, extra_headers=auth + headers)

    def test_regular_and_admin_sessions_cannot_approve_executables(self):
        setup = self.opal.start()
        admin = harness.register('owner', host=self.opal.loopback_authority, setup_token=setup).session_cookie()
        created = self.call('POST', '/api/access/users/create', admin,
                            {'username': 'viewer', 'password': 'viewer-test-pass'})
        self.assertEqual(created.status, 200, created.body)
        viewer = self.call('POST', '/api/auth/login', form={'username': 'viewer', 'password': 'viewer-test-pass'}).session_cookie()
        plugin = self.opal.config_root / 'opal/plugins/fixture'
        plugin.mkdir(parents=True)
        (plugin / 'manifest.json').write_text('{"name":"Review fixture","version":"1"}')
        (plugin / 'search').write_text('#!/usr/bin/env lua\nprint("[]")\n')
        trust_dir = self.opal.config_root / 'opal/plugin-trust'
        before = set(trust_dir.iterdir()) if trust_dir.exists() else set()
        for session in (None, viewer, admin):
            for action in ('approve-exec', 'revoke-exec'):
                response = self.call('POST', '/api/plugins', session,
                                     {'action': action, 'id': 'fixture', 'confirm': '1'})
                self.assertEqual(response.status, 401 if session is None else 403, response.body)
        encoded = self.call('POST', '/api/plugins?action=approve%2dexec&id=fixture&confirm=1', admin)
        self.assertEqual(encoded.status, 403, encoded.body)
        self.assertEqual(before, set(trust_dir.iterdir()) if trust_dir.exists() else set())
        for path, form in (
            ('/api/local-library/action', {'action': 'add-root', 'path': str(self.opal.root)}),
            ('/api/jellyfin/login', {'server': 'http://127.0.0.1:1', 'username': 'x', 'password': 'x'}),
            ('/api/plugins', {'action': 'install', 'id': 'fixture'}),
        ):
            response = self.call('POST', path, viewer, form)
            self.assertEqual(response.status, 403, response.body)
        self.assertEqual(self.call('GET', '/api/status', viewer).status, 200)
        machine = (self.opal.config_root / 'opal/api.token').read_text().strip()
        approved = self.call('POST', '/api/plugins', form={'action': 'approve-exec', 'id': 'fixture', 'confirm': '1'},
                             headers=(("Authorization", 'Bearer ' + machine),))
        self.assertEqual(approved.status, 200, approved.body)
        self.assertTrue(set(trust_dir.iterdir()) - before)

    def test_proxy_mode_sets_secure_cookie_and_refuses_lan_binding(self):
        setup = self.opal.start(https_proxy=True)
        registered = harness.register('owner', host=self.opal.loopback_authority, setup_token=setup)
        self.assertEqual(registered.status, 200, registered.body)
        self.assertIn('; Secure', registered.header_values('set-cookie')[0])
        machine = (self.opal.config_root / 'opal/api.token').read_text().strip()
        changed = self.call('POST', '/api/access/bind', form={'mode': 'lan'},
                            headers=(("Authorization", 'Bearer ' + machine),))
        self.assertEqual(changed.status, 400, changed.body)

    def test_forwarded_header_cannot_enable_proxy_trust(self):
        setup = self.opal.start()
        registered = harness.register('owner', host=self.opal.loopback_authority, setup_token=setup,
                                      extra_headers=(("X-Forwarded-Proto", "https"),))
        self.assertEqual(registered.status, 200, registered.body)
        self.assertNotIn('; Secure', registered.header_values('set-cookie')[0])


if __name__ == '__main__':
    args, rest = harness.parse_args()
    harness.PORT = args.port
    if args.binary:
        harness.BINARY = Path(args.binary).expanduser().resolve()
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)
