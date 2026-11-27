"""Regression tests for the group-A torrent engine repairs (2026-11).

Network-free: every fixture below is a fragment captured from the live provider
on 2026-11-18 (trimmed, not invented), fed through the shipped engine code.
"""
import html
import time
import importlib
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engines'))

# bitsearch.eu /search?q=dune+2021 — one result card (trackers trimmed to one).
BITSEARCH_CARD = '<div class="torrent-result-card bg-white rounded-lg shadow-sm border border-gray-200 p-6 hover:shadow-md transition duration-150 ease-in-out">\n<div class="flex items-start justify-between">\n<!-- Torrent Info -->\n<div class="flex-1 min-w-0">\n<div class="flex items-center space-x-2 mb-2">\n<h3 class="text-base sm:text-lg font-medium text-gray-900 line-clamp-2">\n<a href="/torrent/616c4e220985d20990b5512d" class="hover:text-primary transition duration-150 ease-in-out">\nDune (2021) [1080p] [WEBRip] [5.1] [YTS.MX]\n</a>\n</h3>\n<span class="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-green-100 text-green-800">\n<i class="fas fa-check-circle mr-1"></i>\nVerified\n</span>\n</div>\n<!-- Category and Stats -->\n<div class="torrent-result-meta flex flex-wrap items-center gap-4 text-sm text-gray-600 mb-3">\n<span class="inline-flex items-center space-x-1">\n<i class="fas fa-file text-gray-500"></i>\n<span>Movies/4K/UHD</span>\n</span>\n<span class="inline-flex items-center space-x-1">\n<i class="fas fa-download"></i>\n<span>2.75 GB</span>\n</span>\n<span class="inline-flex items-center space-x-1">\n<i class="fas fa-calendar"></i>\n<span>10/17/2021</span>\n</span>\n</div>\n<!-- Swarm Stats -->\n<div class="torrent-result-meta flex flex-wrap items-center gap-4 text-sm">\n<span class="inline-flex items-center space-x-1 text-green-600">\n<i class="fas fa-arrow-up"></i>\n<span class="font-medium">1050</span>\n<span>seeders</span>\n</span>\n<span class="inline-flex items-center space-x-1 text-red-600">\n<i class="fas fa-arrow-down"></i>\n<span class="font-medium">372</span>\n<span>leechers</span>\n</span>\n<span class="inline-flex items-center space-x-1 text-blue-600">\n<i class="fas fa-download"></i>\n<span class="font-medium">364753</span>\n<span>downloads</span>\n</span>\n</div>\n</div>\n<!-- Download Links -->\n<div class="hidden sm:flex flex-col space-y-2 ml-6">\n<a href="/download/torrent/ED0DA850C273E3E15A819BDCBBF418BC85107EC8?title=Dune (2021) [1080p] [WEBRip] [5.1] [YTS.MX]" \nclass="inline-flex items-center justify-center px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-md hover:bg-blue-700 transition duration-150 ease-in-out">\n<i class="fas fa-download mr-2"></i>\nTorrent\n</a>\n<a href="magnet:?xt&#x3D;urn:btih:ED0DA850C273E3E15A819BDCBBF418BC85107EC8&amp;dn&#x3D;%5Bbitsearch.to%5D%20Dune%20(2021)%20%5B1080p%5D%20%5BWEBRip%5D%20%5B5.1%5D%20%5BYTS.MX%5D&amp;tr&#x3D;udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce" \nclass="inline-flex items-center justify-center px-4 py-2 bg-green-600 text-white text-sm font-medium rounded-md hover:bg-green-700 transition duration-150 ease-in-out">\n<i class="fas fa-magnet mr-2"></i>\nMagnet\n</a>\n</div>\n</div>\n<!-- Mobile Download Links -->'

# www.limetorrents.fun /search/all/dune-2021/seeds/1/ — header + one row.
LIME_TABLE = '<table class="table2" cellpadding="6" cellspacing="0"><tr><th class="thleft">Torrent Name</th><th class="thnormal">Added</th><th class="thnormal">Size</th><th class="thnormal">Seed</th><th class="thnormal">Leech</th><th class="thright">Health</th></tr><tr bgcolor="#F4F4F4"><td class="tdleft"><div class="tt-name"><a href="http://itorrents.net/torrent/ED0DA850C273E3E15A819BDCBBF418BC85107EC8.torrent?title=Dune-(2021)-(1080p)-[WEBRip]-[5-1]-[YTS-MX]" rel="nofollow" class="csprite_dl14"></a><a href="/Dune-(2021)-(1080p)-[WEBRip]-[5-1]-[YTS-MX]-torrent-16686771.html">Dune (2021) (1080p) [WEBRip] [5 1] [YTS MX]</a></div><div class="tt-options"></div></td><td class="tdnormal">1 Year+ - in Movies</a></td><td class="tdnormal">2.75 GB</td><td class="tdseed">1,024</td><td class="tdleech">117</td><td class="tdright"><div class="hb9"></div></td></tr></table>'

# animetosho.org /search?q=one+piece — one entry up to the next date separator.
ANIMETOSHO_ENTRY = '<div class="home_list_entry home_list_entry_alt home_list_entry_compl_1"><div class="date" title="Date/time submitted: 06/05/2026 11:02">11:02</div><div class="date_icon" title="Date/time submitted: 06/05/2026 11:02"><span class="image16 icon_clock"></span></div><div class="size" title="Total file size: 2,012,372,487 bytes">1.874 GB</div><div class="size_icon" title="Total file size: 2,012,372,487 bytes"><span class="image16 icon_dirsize"></span></div><div class="link"><a href="https://animetosho.org/view/one-piece-vol002-dvdrip-480p-x265-10bit-aac-multi-up.n2106671">One.Piece.Vol002.DVDRip.480p.x265.10bit.AAC.Multi-<wbr/>uP</a></div><div class="links"><span class="links_right"><span class="misclinks"><span class="numcomments"><a href="https://nyaa.si/view/2106671" title="Nyaa: Normal"><span style="color: #FBFBFB;">&#9679;</span>Nyaa</a></span></span></span><span class="serieslink"><a href="https://animetosho.org/series/one-piece.69">One Piece</a></span><a href="https://nyaa.si/download/2106671.torrent" class="dllink">Torrent</a>/<a href="magnet:?xt=urn:btih:PDJTN7UDSTJTYMLDI7FWSWCVSAUEFDZA&amp;tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce&amp;tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&amp;dn=One.Piece.Vol002.DVDRip.480p.x265.10bit.AAC.Multi-uP">Magnet</a> <span title="Seeders: 2 / Leechers: 10" style="color: #808080;">[2&#8593;/10&#8595;]</span> <em>(6 files)</em></div></div><div class="home_list_datesep">04/05/2026</div>'

# eztvx.to /api/get-torrents?imdb_id=0944947 — two torrents (screenshots dropped).
EZTV_API = {'imdb_id': '0944947', 'torrents_count': 146, 'limit': 100, 'page': 1, 'torrents': [{'id': 1469305, 'hash': 'a017ac9bf02de9e36f1f9177bdb60612186b0b0d', 'filename': 'Game.of.Thrones.S01E10.2160p.UHD.BluRay.x265-SCOTLUHD[eztv.io].mkv', 'magnet_url': 'magnet:?xt=urn:btih:a017ac9bf02de9e36f1f9177bdb60612186b0b0d&dn=Game.of.Thrones.S01E10.2160p.UHD.BluRay.x265-SCOTLUHD%5Beztvx.to%5D&tr=udp://tracker.opentrackr.org:1337/announce', 'title': 'Game of Thrones S01E10 2160p UHD BluRay x265-SCOTLUHD EZTV', 'imdb_id': '0944947', 'season': '1', 'episode': '10', 'seeds': 10, 'peers': 1, 'date_released_unix': 1594711151, 'size_bytes': '10387327388'}, {'id': 1469303, 'hash': '994ff5674bda5582d4e802dbd320aebf2c2d0642', 'filename': 'Game.of.Thrones.S01E09.2160p.UHD.BluRay.x265-SCOTLUHD[eztv.io].mkv', 'magnet_url': 'magnet:?xt=urn:btih:994ff5674bda5582d4e802dbd320aebf2c2d0642&dn=Game.of.Thrones.S01E09.2160p.UHD.BluRay.x265-SCOTLUHD%5Beztvx.to%5D&tr=udp://tracker.opentrackr.org:1337/announce', 'title': 'Game of Thrones S01E09 2160p UHD BluRay x265-SCOTLUHD EZTV', 'imdb_id': '0944947', 'season': '1', 'episode': '9', 'seeds': 4, 'peers': 0, 'date_released_unix': 1594708960, 'size_bytes': '11257223877'}]}

# What every EZTV mirror answers on /search/ (403 body; retrieve_url returns '').
CLOUDFLARE_WALL = ''


class TorrentEngineRepairsA(unittest.TestCase):
    def run_engine(self, name, responses, query, category='all', url=None):
        module = importlib.import_module('engines.' + name)
        rows, calls = [], []

        def fetch(request_url, *args, **kwargs):
            calls.append(request_url)
            return responses[len(calls) - 1] if len(calls) <= len(responses) else ''

        engine = getattr(module, name)()
        if url:
            engine.url = url
        patches = [patch.object(module, 'retrieve_url', fetch),
                   patch.object(module, 'prettyPrinter', rows.append)]
        if hasattr(module, 'sleep'):
            patches.append(patch.object(module, 'sleep', lambda _s: None))
        for p in patches:
            p.start()
        try:
            engine.search(query, category)
        finally:
            for p in patches:
                p.stop()
        return rows, calls

    # ── bitsearch: card class gained a `torrent-result-card` token → 0 rows ──
    def test_bitsearch_parses_redesigned_result_card(self):
        page = html.unescape(BITSEARCH_CARD)  # retrieve_url unescapes entities
        rows, calls = self.run_engine('bitsearch', [page], 'dune%202021')
        self.assertEqual(len(rows), 1)
        self.assertTrue(calls[0].startswith('https://bitsearch.eu/search?q=dune+2021&page=1'))
        row = rows[0]
        self.assertEqual(row['name'], 'Dune (2021) [1080p] [WEBRip] [5.1] [YTS.MX]')
        self.assertTrue(row['link'].startswith(
            'magnet:?xt=urn:btih:ED0DA850C273E3E15A819BDCBBF418BC85107EC8&dn='))
        self.assertEqual((row['size'], row['seeds'], row['leech']), ('2.75 GB', '1050', '372'))
        self.assertEqual(row['desc_link'], 'https://bitsearch.eu/torrent/616c4e220985d20990b5512d')
        self.assertGreater(row['pub_date'], 0)

    def test_bitsearch_still_parses_the_pre_redesign_card_class(self):
        page = html.unescape(BITSEARCH_CARD).replace('torrent-result-card bg-white', 'bg-white')
        rows, _ = self.run_engine('bitsearch', [page], 'dune')
        self.assertEqual(len(rows), 1)

    # ── bitsearch: swarm counts moved into a nested <span data-swarm-field> ──
    # The old single 8-group lazy regex stopped matching and backtracked for
    # minutes per card while holding the GIL, so nova2's --timeout never fired
    # and every torrent search hung.
    def swarm_card(self):
        page = html.unescape(BITSEARCH_CARD)
        for field, count in (('seeders', '1050'), ('leechers', '372')):
            page = page.replace(f'<span class="font-medium">{count}</span>',
                                f'<span class="font-medium"><span data-swarm-id="616c" data-swarm-field="{field}">{count}</span></span>')
        return page

    def test_bitsearch_reads_nested_swarm_spans(self):
        rows, _ = self.run_engine('bitsearch', [self.swarm_card()], 'dune')
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]['seeds'], rows[0]['leech']), ('1050', '372'))
        rows, _ = self.run_engine('solidtorrents', [self.swarm_card()], 'dune')
        self.assertEqual((rows[0]['seeds'], rows[0]['leech']), (1050, 372))

    def test_bitsearch_unparseable_cards_return_quickly(self):
        # Cards missing fields must be skipped in linear time, not backtracked.
        card = self.swarm_card().replace('href="magnet:', 'href="nomagnet:')
        page = ' '.join((card * 20).split())
        module = importlib.import_module('engines.bitsearch')
        parser = module.bitsearch.HTMLParser('https://bitsearch.eu/')
        started = time.monotonic()
        self.assertEqual(parser._HTMLParser__findTorrents(page), [])
        self.assertLess(time.monotonic() - started, 1.0)

    # ── solidtorrents: domain 301s to BitSearch; old parser matched nothing ──
    def test_solidtorrents_reads_bitsearch_markup_sorted_by_seeders(self):
        page = html.unescape(BITSEARCH_CARD)
        rows, calls = self.run_engine('solidtorrents', [page], 'dune%202021', 'music')
        self.assertEqual(calls, ['https://bitsearch.eu/search?q=dune+2021&category=7&sortBy=seeders&page=1'])
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row['name'], 'Dune (2021) [1080p] [WEBRip] [5.1] [YTS.MX]')
        self.assertIn('btih:ED0DA850C273E3E15A819BDCBBF418BC85107EC8', row['link'])
        self.assertEqual((row['size'], row['seeds'], row['leech']), ('2.75 GB', 1050, 372))
        self.assertEqual(row['desc_link'], 'https://bitsearch.eu/torrent/616c4e220985d20990b5512d')
        self.assertGreater(row['pub_date'], 0)

    def test_solidtorrents_all_category_omits_filter_and_survives_installed_legacy_base(self):
        rows, calls = self.run_engine('solidtorrents', [html.unescape(BITSEARCH_CARD)], 'dune',
                                      url='https://solidtorrents.to')
        self.assertEqual(calls, ['https://solidtorrents.to/search?q=dune&sortBy=seeders&page=1'])
        self.assertEqual(rows[0]['desc_link'], 'https://solidtorrents.to/torrent/616c4e220985d20990b5512d')
        self.assertEqual(self.run_engine('solidtorrents', ['<html>Just a moment...</html>'], 'dune')[0], [])

    # ── limetorrents: moved to .fun; rows were detail-page URLs, not magnets ──
    def test_limetorrents_default_host_and_magnet_from_row_infohash(self):
        rows, calls = self.run_engine('limetorrents', [html.unescape(LIME_TABLE)], 'dune%202021')
        self.assertEqual(calls, ['https://www.limetorrents.fun/search/all/dune-2021/seeds/1/'])
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row['name'], 'Dune (2021) (1080p) [WEBRip] [5 1] [YTS MX]')
        self.assertTrue(row['link'].startswith(
            'magnet:?xt=urn:btih:ed0da850c273e3e15a819bdcbbf418bc85107ec8&dn=Dune%20'))
        self.assertNotIn('btih', row)  # scratch key never reaches the printer
        self.assertTrue(row['desc_link'].startswith('https://www.limetorrents.fun/Dune-'))
        self.assertTrue(row['desc_link'].endswith('-torrent-16686771.html'))
        self.assertEqual((row['size'], row['seeds'], row['leech']), ('2.75 GB', '1024', '117'))

    def test_limetorrents_row_without_infohash_keeps_detail_link(self):
        page = html.unescape(LIME_TABLE).replace('ED0DA850C273E3E15A819BDCBBF418BC85107EC8', 'nothex')
        rows, _ = self.run_engine('limetorrents', [page], 'dune')
        self.assertEqual(rows[0]['link'], rows[0]['desc_link'])

    # ── animetosho: feed host is NXDOMAIN; fall back to the site listing ──────
    def test_animetosho_falls_back_to_site_listing_when_feed_host_is_gone(self):
        rows, calls = self.run_engine('animetosho', ['', ANIMETOSHO_ENTRY], 'one%20piece')
        self.assertEqual(calls, ['https://feed.animetosho.org/json?q=one+piece',
                                 'https://animetosho.org/search?q=one+piece'])
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row['name'], 'One.Piece.Vol002.DVDRip.480p.x265.10bit.AAC.Multi-uP')
        # base32 xt PDJTN7UD… → canonical lowercase hex, trackers preserved.
        self.assertTrue(row['link'].startswith(
            'magnet:?xt=urn:btih:78d336fe8394d33c316347cb6958559028428f20&dn=One.Piece.Vol002'))
        self.assertIn('tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce', row['link'])
        self.assertEqual((row['size'], row['seeds'], row['leech']), (2012372487, 2, 10))
        self.assertEqual(row['pub_date'], 1778065320)  # 06/05/2026 11:02 UTC (dd/mm)
        self.assertEqual(row['desc_link'],
                         'https://animetosho.org/view/one-piece-vol002-dvdrip-480p-x265-10bit-aac-multi-up.n2106671')

    def test_animetosho_site_base_skips_dead_feed_and_dedupes(self):
        rows, calls = self.run_engine('animetosho', [ANIMETOSHO_ENTRY + ANIMETOSHO_ENTRY], 'one%20piece',
                                      url='https://animetosho.org')
        self.assertEqual(calls, ['https://animetosho.org/search?q=one+piece'])
        self.assertEqual(len(rows), 1)

    def test_animetosho_listing_drops_entries_without_a_valid_magnet(self):
        bad = ANIMETOSHO_ENTRY.replace('PDJTN7UDSTJTYMLDI7FWSWCVSAUEFDZA', 'not-a-hash')
        ddl_only = ANIMETOSHO_ENTRY.replace('href="magnet:', 'href="https://example.invalid/')
        rows, _ = self.run_engine('animetosho', ['<html>Feed disabled</html>', bad + ddl_only], 'x')
        self.assertEqual(rows, [])

    # ── eztv: /search/ is Cloudflare-walled on every mirror; use the JSON API ─
    def test_eztv_split_query(self):
        split = importlib.import_module('engines.eztv').eztv.split_query
        self.assertEqual(split('severance%20s02e01%201080p'), ('severance', 2, 1, ['1080p']))
        self.assertEqual(split('game of thrones season 1'), ('game of thrones', 1, None, []))
        self.assertEqual(split('dune 2021'), ('dune', None, None, []))
        self.assertEqual(split('the office 3x07 x265'), ('the office', 3, 7, ['x265']))
        self.assertEqual(split('1923'), ('1923', None, None, []))  # a title, not a year filter
        self.assertEqual(split(''), ('', None, None, []))

    def test_eztv_walled_search_falls_back_to_imdb_api(self):
        tvmaze = json.dumps({'name': 'Game of Thrones', 'externals': {'imdb': 'tt0944947'}})
        rows, calls = self.run_engine('eztv', [CLOUDFLARE_WALL, tvmaze, json.dumps(EZTV_API)],
                                      'game%20of%20thrones%20s01e09')
        self.assertEqual(calls[1], 'https://api.tvmaze.com/singlesearch/shows?q=game%20of%20thrones')
        self.assertEqual(calls[2], 'https://eztvx.to/api/get-torrents?imdb_id=0944947&limit=100&page=1')
        self.assertEqual(len(calls), 3)  # short page: no further paging
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row['name'], 'Game of Thrones S01E09 2160p UHD BluRay x265-SCOTLUHD EZTV')
        self.assertTrue(row['link'].startswith('magnet:?xt=urn:btih:994ff5674bda5582d4e802dbd320aebf2c2d0642&'))
        self.assertEqual((row['size'], row['seeds'], row['leech'], row['pub_date']),
                         (11257223877, 4, 0, 1594708960))

    def test_eztv_api_filters_tokens_and_rejects_wrong_show_or_bad_ids(self):
        eztv = importlib.import_module('engines.eztv').eztv
        body = json.dumps(EZTV_API)
        self.assertEqual(len(eztv.api_rows(body, None, None, [], 'u')[0]), 2)
        self.assertEqual(len(eztv.api_rows(body, 1, None, ['2160p', 'game', 'thrones'], 'u')[0]), 2)
        self.assertEqual(eztv.api_rows(body, 2, None, [], 'u')[0], [])
        self.assertEqual(eztv.api_rows(body, None, None, ['1080p'], 'u')[0], [])
        # TVMaze fuzzy-matched some other show: its title words are absent.
        self.assertEqual(eztv.api_rows(body, None, None, ['severance'], 'u'), ([], 2))
        self.assertEqual(eztv.api_rows('<html>Just a moment...</html>', None, None, [], 'u'), ([], 0))
        for externals in ({}, {'imdb': None}, {'imdb': 'tt1&page=9'}):
            rows, calls = self.run_engine('eztv', ['', json.dumps({'externals': externals})], 'show')
            self.assertEqual((rows, len(calls)), ([], 2))
        rows, calls = self.run_engine('eztv', ['', ''], 'not%20a%20show')  # TVMaze 404
        self.assertEqual((rows, len(calls)), ([], 2))


if __name__ == '__main__':
    unittest.main()
