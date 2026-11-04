"""Owned loopback Jackett API + managed process tests; no tracker accounts."""
import contextlib
import hashlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'engines'))
import opal_sources
with patch.object(opal_sources, 'load', return_value={'base': 'http://127.0.0.1:9117', 'apikey': 'test'}):
    import engines.jackett as engine
spec = importlib.util.spec_from_file_location('jackett_manager', ROOT / 'src/services/jackett_manager.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)

CATALOG = '''<indexers>
<indexer id="public-one" configured="true"><type>public</type></indexer>
<indexer id="public-two" configured="true"><type>public</type></indexer>
<indexer id="torrentleech" configured="true"><type>private</type></indexer>
<indexer id="member" configured="true"><type>semi-private</type></indexer>
<indexer id="../escape" configured="true"><type>public</type></indexer>
<indexer id="off" configured="false"><type>public</type></indexer>
<indexer id="public-one" configured="true"><type>public</type></indexer>
</indexers>'''
RSS = '''<rss xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><item>
<title>Owned test film</title><jackettindexer>Public</jackettindexer>
<link>magnet:?xt=urn:btih:0123456789012345678901234567890123456789</link>
<size>4096</size><torznab:attr name="seeders" value="5"/>
<torznab:attr name="peers" value="2"/></item></channel></rss>'''


class SearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        owner = cls
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                uri = urlsplit(self.path)
                params = parse_qs(uri.query)
                owner.requests.append((uri.path, params))
                if owner.redirect:
                    self.send_response(302)
                    self.send_header('Location', owner.base + '/stolen?apikey=secret')
                    self.end_headers()
                    return
                body = owner.catalog if params.get('t') == ['indexers'] else owner.rss
                self.send_response(200)
                self.send_header('Content-Length', str(len(body.encode())))
                self.end_headers()
                try: self.wfile.write(body.encode())
                except (BrokenPipeError, ConnectionResetError): pass
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.base = f'http://127.0.0.1:{cls.server.server_port}/jackett'
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def setUp(self):
        type(self).requests = []
        type(self).catalog = CATALOG
        type(self).rss = RSS
        type(self).redirect = False
        self.client = engine.jackett()
        self.client.url = self.base
        self.client.api_key = 'private-key&test'
        self.rows = []
        self.client.pretty_printer_thread_safe = self.rows.append
        self.config = patch.dict(engine.CONFIG_DATA, {'indexers': '*', 'tracker_first': False}, clear=True)
        self.config.start()
        self.addCleanup(self.config.stop)

    def test_selected_indexers_and_categories_survive_single_and_multi_worker(self):
        for threads in (1, 8):
            type(self).requests = []
            self.rows.clear()
            self.client.thread_count = threads
            engine.CONFIG_DATA['indexers'] = 'public-two'
            self.client.search('A%20%26%20B', 'movies')
            self.assertEqual(len(self.rows), 1)
            path, params = self.requests[-1]
            self.assertEqual(path, '/jackett/api/v2.0/indexers/public-two/results/torznab/api')
            self.assertEqual(params['apikey'], ['private-key&test'])
            self.assertEqual(params['t'], ['search'])
            self.assertEqual(params['cat'], ['2000'])
            self.assertEqual(params['q'], ['A & B'])
            self.assertEqual(self.rows[0]['leech'], 0)

    def test_aggregate_does_not_query_private_semi_private_or_unconfigured_trackers(self):
        self.client.search('test')
        self.assertEqual(len(self.rows), 2)
        searched = {p.split('/')[5] for p, q in self.requests if q.get('t') == ['search']}
        self.assertEqual(searched, {'public-one', 'public-two'})

    def test_empty_selection_and_empty_catalog_never_create_zero_worker_pool(self):
        for catalog, selection in [(CATALOG, ''), ('<indexers/>', '*')]:
            type(self).catalog = catalog
            engine.CONFIG_DATA['indexers'] = selection
            for threads in (1, 8):
                self.client.thread_count = threads
                self.client.search('test')
        self.assertEqual(self.rows, [])

    def test_invalid_catalog_and_search_xml_do_not_crash_or_emit_fake_rows(self):
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            type(self).catalog = '<html>login'
            self.client.search('test')
            type(self).catalog = CATALOG
            type(self).rss = '<rss>'
            self.client.search('test')
        self.assertEqual(self.rows, [])
        self.assertNotIn(self.client.api_key, errors.getvalue())
        self.assertIn('invalid', errors.getvalue())

    def test_redirects_cannot_forward_credentials(self):
        type(self).redirect = True
        with contextlib.redirect_stderr(io.StringIO()): self.client.search('test')
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.rows, [])

    def test_oversized_catalog_is_rejected(self):
        type(self).catalog = 'x' * (engine.MAX_RESPONSE + 1)
        with contextlib.redirect_stderr(io.StringIO()): self.client.search('test')
        self.assertEqual(self.rows, [])

    def test_bad_numeric_metadata_does_not_discard_other_results(self):
        type(self).rss = RSS.replace('value="5"', 'value="unknown"')
        self.client.search('test')
        self.assertEqual(len(self.rows), 2)
        self.assertEqual(self.rows[0]['seeds'], -1)

    def test_unsupported_category_does_not_contact_server(self):
        self.client.search('test', 'comics-invalid')
        self.assertEqual(self.requests, [])


class ManagedTests(unittest.TestCase):
    def test_release_matrix_is_pinned_with_hashes(self):
        for system, cpu in manager.ASSETS:
            name, digest = manager.asset_for(system, cpu)
            self.assertTrue(name.endswith(('.tar.gz', '.zip')))
            self.assertEqual(len(bytes.fromhex(digest)), 32)
        with self.assertRaises(KeyError): manager.asset_for('Plan9', 'mips')

    def test_archive_rejects_traversal_and_links(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, kind in [('../escape', tarfile.REGTYPE), ('link', tarfile.SYMTYPE)]:
                archive = root / 'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    info.linkname = '/etc/passwd'
                    tar.addfile(info)
                with self.assertRaises(ValueError): manager.extract(archive, root / 'stage')
            self.assertFalse((root.parent / 'escape').exists())

    def test_bad_checksum_never_publishes_release(self):
        class Response(io.BytesIO):
            def geturl(self): return 'https://release-assets.githubusercontent.com/owned'
        with tempfile.TemporaryDirectory() as temp, patch.object(manager.urllib.request, 'urlopen', return_value=Response(b'corrupt')):
            with self.assertRaisesRegex(ValueError, 'checksum'):
                manager.download('https://github.com/Jackett/Jackett/releases/owned', Path(temp) / 'artifact', '0' * 64)

    def test_config_is_loopback_only_preserves_accounts_and_uses_private_permissions(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            data, base, key = manager.prepare_config(root)
            (data / 'Indexers').mkdir()
            saved = data / 'Indexers' / 'owned.json'
            saved.write_text('{"account":"retained"}')
            data2, _, key2 = manager.prepare_config(root)
            self.assertEqual((data2, key2), (data, key))
            self.assertTrue(base.startswith('http://127.0.0.1:'))
            cfg = json.loads((data / 'ServerConfig.json').read_text())
            self.assertFalse(cfg['AllowExternal'])
            self.assertTrue(cfg['UpdateDisabled'])
            self.assertTrue(saved.exists())
            if os.name != 'nt': self.assertEqual((data / 'ServerConfig.json').stat().st_mode & 0o777, 0o600)

    @unittest.skipIf(os.name == 'nt', 'POSIX owned-process fixture')
    def test_owned_runner_starts_authenticates_and_stops_child_without_external_install(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / manager.VERSION / 'Jackett' / 'jackett'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!' + sys.executable + '''
import sys,json,http.server,pathlib,os
p=pathlib.Path(sys.argv[sys.argv.index('--DataFolder')+1]);c=json.loads((p/'ServerConfig.json').read_text())
(p/'child.pid').write_text(str(os.getpid()))
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  self.send_response(200 if c['APIKey'] in self.path else 403);self.end_headers();self.wfile.write(b'<indexers />')
http.server.HTTPServer(('127.0.0.1',c['Port']),H).serve_forever()
''')
            binary.chmod(0o700)
            process = subprocess.Popen([sys.executable, str(ROOT / 'src/services/jackett_manager.py'), '--root', temp],
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            try:
                import select
                deadline = time.monotonic() + 8
                events = []
                while time.monotonic() < deadline:
                    readable, _, _ = select.select([process.stdout], [], [], .2)
                    if readable:
                        line = process.stdout.readline()
                        if not line: break
                        event = json.loads(line)
                        events.append(event)
                        if event['event'] == 'ready': break
                self.assertEqual(events[-1]['event'], 'ready', events)
                child_pid = int((root / 'data/child.pid').read_text())
                process.terminate()
                self.assertEqual(process.wait(timeout=4), 0)
                with self.assertRaises(ProcessLookupError): os.kill(child_pid, 0)
                self.assertTrue((root / 'data/ServerConfig.json').exists())
            finally:
                if process.poll() is None: process.kill(); process.wait()
                process.stdout.close()


if __name__ == '__main__': unittest.main()
