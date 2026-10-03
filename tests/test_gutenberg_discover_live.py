#!/usr/bin/env python3
"""Opt-in actual Gutenberg public metadata checks; never downloads book text.
Offline progressive/stall fixtures live in opds.verifyGutenbergProgressiveForTest.
"""
import argparse
from pathlib import Path
import sqlite3
import time
import unittest
import test_setup_token_live as live

PUBLIC = False


class GutenbergDiscovery(unittest.TestCase):
    def setUp(self):
        if not PUBLIC:
            self.skipTest('pass --public to verify publisher metadata')
        self.opal = live.IsolatedOpal(self)
        self.addCleanup(self.opal.stop)
        profile = self.opal.config_root/'opal'
        profile.mkdir(parents=True)
        with sqlite3.connect(profile/'opal.db') as db:
            db.execute("CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT NOT NULL DEFAULT '')")
            db.executemany('INSERT INTO config VALUES(?,?)', [('web_port', str(live.PORT)), ('web_bind', 'loopback'), ('content_cache_enabled', '0'), ('search_sources', '0')])
        token = self.opal.start()
        account = live.register('gutenberg-metadata-check', host=self.opal.loopback_authority, setup_token=token)
        self.assertEqual(account.status, 200)
        self.headers = (('Cookie', account.session_cookie()),)

    def api(self, path, method='GET', form=None):
        response = live.request(method, '/api/'+path, host=self.opal.loopback_authority,
                                origin='http://'+self.opal.loopback_authority if method == 'POST' else None,
                                form=form, extra_headers=self.headers)
        self.assertEqual(response.status, 200)
        return response.json()

    def until(self, path, ready, timeout=45):
        end = time.monotonic()+timeout
        while time.monotonic() < end:
            data = self.api(path)
            if ready(data):
                return data
            time.sleep(.05)
        self.fail('Publisher metadata did not complete within bounded deadline')

    def test_discover_merges_real_sections_and_filters_keep_reader_action(self):
        self.api('opds/connect', 'POST', {'server': 'https://www.gutenberg.org/ebooks.opds/', 'user': '', 'pass': ''})
        first = self.until('opds', lambda d: bool(d['entries']))
        self.assertTrue(first['discovery'])
        self.assertTrue(all(row.get('gutenberg') for row in first['entries']))
        merged = self.until('opds', lambda d: not d['loading'])
        self.assertFalse(merged['error'])
        self.assertGreater(len(merged['entries']), 3)
        self.assertEqual({c['title'] for c in merged['categories']}, {'Popular', 'Latest', 'Random'})
        self.assertIn('Discover', merged['feed'])
        count = len(merged['entries'])
        self.api('opds/more', 'POST')
        self.until('opds', lambda d: len(d['entries']) > count)
        self.api('opds/category?idx=0', 'POST')
        category = self.until('opds', lambda d: not d['loading'] and not d['discovery'])
        self.assertTrue(category['entries'])
        self.assertTrue(all(row.get('gutenberg') for row in category['entries']))
        chosen = category['entries'][0]['title']
        stale = live.request('POST', '/api/opds/open?idx=0&generation='+str(category['generation']+1), host=self.opal.loopback_authority, origin='http://'+self.opal.loopback_authority, extra_headers=self.headers)
        self.assertEqual(stale.status, 409)
        self.api('opds/open?idx=0&generation='+str(category['generation']), 'POST')
        reader = self.until('novels', lambda d: d['view'] == 'chapters' and not d['chapters_loading'])
        self.assertEqual(reader['title'], chosen)
        self.assertEqual(len(reader['chapters']), 1)
        self.assertFalse(reader['text_loading'])
        # No /novels/chapter or acquisition request: only catalog/detail metadata.


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--port', type=int, default=41813)
    parser.add_argument('--public', action='store_true')
    args, remaining = parser.parse_known_args()
    live.BINARY = args.binary.resolve()
    live.PORT = args.port
    PUBLIC = args.public
    unittest.main(argv=[__file__]+remaining)
