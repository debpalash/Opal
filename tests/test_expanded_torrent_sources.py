"""Exercise the shipped source requests and parsed nova2 output without network."""
import importlib
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engines'))


class ExpandedTorrentSources(unittest.TestCase):
    def run_engine(self, name, responses, query, category='all'):
        module = importlib.import_module('engines.' + name)
        rows, calls = [], []
        def fetch(url, *args, **kwargs):
            calls.append(url)
            return responses[len(calls) - 1]
        with patch.object(module, 'retrieve_url', fetch), patch.object(module, 'prettyPrinter', rows.append):
            getattr(module, name)().search(query, category)
        return rows, calls

    def test_nekobt_uses_actual_query_parameter_and_rejects_hidden_or_invalid_magnets(self):
        row = {'id': '123', 'title': 'Episode\nOne', 'magnet': 'magnet:?xt=urn:btih:' + 'a' * 40,
               'filesize': '4096', 'seeders': '8', 'leechers': 'bad'}
        body = json.dumps({'data': {'results': [row, row, {**row, 'hidden': True},
                                                 {**row, 'magnet': 'javascript:bad'}]}})
        rows, calls = self.run_engine('nekobt', [body], 'One%20Piece%26dub')
        self.assertEqual(len(rows), 1)
        self.assertIn('query=One+Piece%26dub', calls[0])
        self.assertEqual(rows[0]['name'], 'Episode One')
        self.assertEqual(rows[0]['size'], 4096)
        self.assertEqual(rows[0]['seeds'], 8)
        self.assertEqual(rows[0]['leech'], -1)
        self.assertEqual(rows[0]['desc_link'], 'https://nekobt.to/torrents/123')

    def test_shana_returns_episode_torrent_instead_of_series_page(self):
        body = ('<div id="rel123" class="release_block"><div class="release_episode">12</div>'
                '<div class="release_title"><div class="release_text_contents"><a href="/series/1/">A &amp; B</a></div></div>'
                '<div class="release_subber"><div>Group</div></div><div class="release_size release_last">1.2GB</div>'
                '<a href="/download/123/">Download</a></div>')
        rows, calls = self.run_engine('shanaproject', [body], 'A%26B')
        self.assertEqual(rows[0]['link'], 'https://www.shanaproject.com/download/123/')
        self.assertIn('A & B - 12', rows[0]['name'])
        self.assertEqual(rows[0]['seeds'], -1)
        self.assertIn('title=A%26B', calls[0])

    def test_publicdomain_requires_all_terms_and_resolves_tls_torrent_links(self):
        catalog = ('<a href=nshowmovie.html?movieid=1>A Bucket of Blood</a>'
                   '<a href=nshowmovie.html?movieid=2>Blood Only</a>')
        detail = ('<a href="http://www.publicdomaintorrents.com/bt/btdownload.php?type=torrent&amp;file=movie.mp4.torrent">MP4</a>'
                  '<a href="https://evil.invalid/movie.torrent">Bad</a>')
        rows, calls = self.run_engine('publicdomaintorrents', [catalog, detail], 'bucket%20blood', 'movies')
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['link'], 'https://www.publicdomaintorrents.com/bt/btdownload.php?type=torrent&file=movie.mp4.torrent')
        self.assertEqual(rows[0]['seeds'], -1)

    def test_anime_sources_do_not_emit_for_unsupported_music_category(self):
        for name in ['nekobt', 'shanaproject']:
            rows, calls = self.run_engine(name, [], 'track', 'music')
            self.assertEqual((rows, calls), ([], []))


if __name__ == '__main__':
    unittest.main()
