"""Production Nova source adapters: deterministic responses, no provider network."""
import importlib
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engines'))


class GitHubTorrentSources(unittest.TestCase):
    def run_engine(self, name, body, query='Naruto%20dub%26sub', category='all'):
        module = importlib.import_module('engines.' + name)
        rows = []
        with patch.object(module, 'retrieve_url', return_value=body) as fetch, patch.object(module, 'prettyPrinter', rows.append):
            getattr(module, name)().search(query, category)
        return rows, fetch.call_args_list

    def test_subsplease_search_returns_actual_release_magnets_and_sizes(self):
        digest = 'a' * 40
        release = {'show': 'Naruto', 'episode': '4', 'page': 'naruto', 'downloads': [
            {'res': '1080', 'magnet': 'magnet:?xt=urn:btih:' + digest + '&dn=%5BSubsPlease%5D+Naruto+-+04+%281080p%29.mkv&xl=4096'},
            {'res': '720', 'magnet': 'javascript:wrong'}]}
        rows, calls = self.run_engine('subsplease', json.dumps({'Naruto - 04': release}))
        self.assertEqual(len(rows), 1)
        self.assertIn('f=search', calls[0].args[0])
        self.assertIn('s=Naruto+dub%26sub', calls[0].args[0])
        self.assertEqual(rows[0]['name'], '[SubsPlease] Naruto - 04 (1080p).mkv')
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:' + digest))
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech']), (4096, -1, -1))
        self.assertEqual(rows[0]['desc_link'], 'https://subsplease.org/shows/naruto/')

    def test_dmhy_rss_converts_base32_identity_without_inventing_swarm_or_size(self):
        body = ('<rss><channel><item><title>A &amp; B | Episode 4</title>'
                '<link>http://share.dmhy.org/topics/view/123.html</link>'
                '<enclosure url="magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&amp;tr=https%3A%2F%2Ftracker.test%2Fannounce" length="1"/>'
                '</item></channel></rss>')
        rows, calls = self.run_engine('dmhy', body)
        self.assertEqual(len(rows), 1)
        self.assertIn('keyword=Naruto+dub%26sub', calls[0].args[0])
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:' + '0' * 40))
        self.assertEqual(rows[0]['name'], 'A & B Episode 4')
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech']), (-1, -1, -1))
        self.assertEqual(rows[0]['desc_link'], 'https://share.dmhy.org/topics/view/123.html')

    def test_acgrip_uses_actual_torrent_enclosure_and_namespaced_size(self):
        body = ('<rss xmlns:torrent="http://xmlns.ezrss.it/0.1/"><channel><item>'
                '<title>Anime episode</title><link>https://acg.rip/t/123</link>'
                '<enclosure url="https://acg.rip/t/123.torrent" type="application/x-bittorrent"/>'
                '<torrent:contentLength>123456</torrent:contentLength></item></channel></rss>')
        rows, calls = self.run_engine('acgrip', body)
        self.assertIn('/.xml?term=Naruto+dub%26sub', calls[0].args[0])
        self.assertEqual(rows[0]['link'], 'https://acg.rip/t/123.torrent')
        self.assertEqual((rows[0]['size'], rows[0]['seeds']), (123456, -1))

    def test_adapters_reject_unsupported_categories_before_network(self):
        for name in ['subsplease', 'dmhy', 'acgrip']:
            rows, calls = self.run_engine(name, '', category='music')
            self.assertEqual((rows, calls), ([], []))

    def test_acgrip_rejects_untrusted_enclosure_hosts_and_detail_page_as_download(self):
        body = ('<rss><channel><item><title>Wrong</title><enclosure url="https://evil.test/1.torrent"/></item>'
                '<item><title>Wrong2</title><enclosure url="https://acg.rip/t/12"/></item></channel></rss>')
        rows, _ = self.run_engine('acgrip', body)
        self.assertEqual(rows, [])

    def test_sources_respect_configured_mirror_base(self):
        for name in ['subsplease', 'dmhy', 'acgrip']:
            module = importlib.import_module('engines.' + name)
            instance = getattr(module, name)()
            instance.url = 'https://mirror.example.test'
            with patch.object(module, 'retrieve_url', return_value='{}' if name == 'subsplease' else '<rss/>') as fetch:
                instance.search('Naruto', 'all')
            self.assertTrue(fetch.call_args.args[0].startswith(instance.url + '/'))

    def test_malformed_or_oversized_responses_never_emit_partial_results(self):
        for name in ['subsplease', 'dmhy', 'acgrip']:
            for body in ['not a response', 'x' * (4 * 1024 * 1024 + 1)]:
                rows, _ = self.run_engine(name, body)
                self.assertEqual(rows, [])

    def test_duplicate_release_hashes_are_only_emitted_once(self):
        release = {'downloads': [{'magnet': 'magnet:?xt=urn:btih:' + 'a' * 40}]}
        rows, _ = self.run_engine('subsplease', json.dumps({'One': release, 'Duplicate': release}))
        self.assertEqual(len(rows), 1)

    def test_bounded_fetch_preserves_exact_fit_and_rejects_wire_or_gzip_overflow(self):
        import gzip
        import io
        import helpers
        class Response(io.BytesIO):
            def getheader(self, key, default=''):
                return default
        for body, limit, expected in [(b'abcdefgh', 8, 'abcdefgh'),
                                      (b'abcdefghi', 8, ''),
                                      (gzip.compress(b'x' * 128), 64, ''),
                                      (gzip.compress(b'abc'), 64, 'abc')]:
            with patch.object(helpers.urllib.request, 'urlopen', return_value=Response(body)):
                self.assertEqual(helpers.retrieve_url('https://fixture.test/feed', max_bytes=limit), expected)

    def test_xml_external_entities_are_rejected(self):
        body = '<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss><channel><item><title>&x;</title></item></channel></rss>'
        for name in ['dmhy', 'acgrip']:
            rows, _ = self.run_engine(name, body)
            self.assertEqual(rows, [])


if __name__ == '__main__':
    unittest.main()
