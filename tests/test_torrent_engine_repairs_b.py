"""Regression tests for the group-B torrent engine repairs. Network-free: every
response below is a trimmed capture of what the live provider served."""
import importlib
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engines'))

HASH_A = 'C50C83BCF28CE06475A9C2CBB9196C712FC38358'
HASH_B = '61459EB0E1D1673D7FCA4411953829CC67B66C1D'

TT_ROW = (
    '<tr class="{cls}"><td rowspan="2"><a href="/?cat=7"><span class="sprite_cat-raw"></span></a></td>'
    '<td class="desc-top"><a href="magnet:?xt=urn:btih:{b32}&amp;tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce">'
    '<span class="sprite_magnet"></span></a> <a rel="nofollow" type="application/x-bittorrent" '
    'href="https://nyaa.si/download/{id}.torrent">[Raws] One Piece - {id} (1080p).<span class="s"> </span>mkv</a></td>'
    '<td class="web"><a rel="nofollow" href="details.php?id={id}">Details</a></td></tr>'
    '<tr class="{cls}"><td class="desc-bot">Submitter: <a href="?username=N">N</a> | Size: 468.17MB | '
    'Date: 2026-11-14 01:40 UTC</td><td align="right" class="stats">S: <span style="color: green">199</span> '
    'L: <span style="color: green">7</span> C: <span style="color: green">1289</span> ID: {id}</td></tr>')


def tt_page(rows, pager=''):
    return '<html><table class="listing">' + pager + ''.join(rows) + '</table></html>'


TGX_ROW = (
    '<div class="tgxtablerow txlight" data-poster="x.jpg"> <div class="tgxtablecell shrink rounded txlight"> '
    '<a href="/get-posts/category:Movies:time:10D"><small>Movies</small></a> </div> '
    '<div class="tgxtablecell clickable-row click textshadow rounded txlight" '
    'data-href="/post-detail/97ef63/dune-2021-2160p/" style="word-break:break-all;"> <div>'
    '<a class="txlight" title="Dune.2021.2160p.WEBRip" href="/post-detail/97ef63/dune-2021-2160p/">'
    '<span src="torrent"><b>Dune.2021.2160p.WEBRip</b></span></a> '
    '<a href="/imdb-detail/tt1160419/" title="All releases"><img src="/static/tgx/images/imdb_icon.png"></a> </div> </div> '
    '<div class="tgxtablecell collapsehide rounded txlight"><a href="http://itorrents.org/torrent/' + HASH_A + '.torrent" '
    'rel="nofollow">t</a><a href="magnet:?xt=urn:btih:' + HASH_A + '&amp;dn=Dune.2021.2160p.WEBRip&amp;'
    'tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce" rel="nofollow" role="button">m</a></div> '
    '<div class="tgxtablecell collapsehide rounded txlight" style="text-align:right;">'
    '<span class="badge badge-secondary txlight" style="border-radius:4px;">61.1 GB</span></div> '
    '<div class="tgxtablecell collapsehide rounded txlight"><span class="badge badge-warning" title="Views"> '
    '<font color="orange"><b>1</b></font> </span></div> <div class="tgxtablecell collapsehide rounded txlight">'
    '<span title="Seeders/Leechers">[<font color="green"><b>43</b></font>/<font color="#ff0000"><b>20</b></font>]</span></div> '
    '<div class="tgxtablecell bighide rounded txlight"> <table style="width:100%"> <tbody> <tr> '
    '<td align="center"> Size <span class="badge badge-secondary">61.1 GB</span></td> </tr> </tbody> </table> </div>')


class EngineRepairsB(unittest.TestCase):
    def run_engine(self, name, responses, query, category='all'):
        """Run the shipped search() with fetch + printer replaced. `responses`
        is a list (served in order, '' once exhausted) or a callable(url)."""
        module = importlib.import_module('engines.' + name)
        rows, calls = [], []

        def fetch(url, *args, **kwargs):
            calls.append((url, args, kwargs))
            if callable(responses):
                return responses(url)
            return responses[len(calls) - 1] if len(calls) <= len(responses) else ''

        patches = [patch.object(module, 'retrieve_url', fetch),
                   patch.object(module, 'prettyPrinter', lambda row: rows.append(dict(row)))]
        if hasattr(module, 'sleep'):
            patches.append(patch.object(module, 'sleep', lambda *_: None))
        for p in patches:
            p.start()
        try:
            getattr(module, name)().search(query, category)
        finally:
            for p in patches:
                p.stop()
        return rows, calls

    # ── knaben ───────────────────────────────────────────────────────────────

    def test_knaben_sends_a_search_type_the_api_applies(self):
        """Regression: 'score' is not a valid search_type, so the API ignored the
        query and "dune 2021" returned "Rhinoceros v6.13 + Crack"."""
        hit = {'title': 'Dune (2021) [1080p] [WEBRip]', 'hash': HASH_A, 'bytes': 2040109466,
               'seeders': 1059, 'peers': 80, 'details': 'https://yts.mx/movies/dune-2021',
               'magnetUrl': 'magnet:?xt=urn:btih:' + HASH_A + '&dn=Dune'}
        rows, calls = self.run_engine('knaben', [json.dumps({'hits': [hit], 'total': {'value': 230}})],
                                      'dune%202021')
        body = json.loads(calls[0][1][1].decode('utf-8'))
        self.assertEqual(body['search_type'], '100%')
        self.assertEqual(body['search_field'], 'title')
        self.assertEqual(body['query'], 'dune 2021')
        self.assertLessEqual(body['size'], 50)
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]['name'], rows[0]['seeds'], rows[0]['size']),
                         ('Dune (2021) [1080p] [WEBRip]', '1059', '2040109466'))

    # ── therarbg ─────────────────────────────────────────────────────────────

    def rarbg_page(self, results, nxt=None):
        return json.dumps({'links': {'next': nxt, 'previous': None}, 'page_size': 50,
                           'count': len(results), 'total': 1250, 'results': results})

    def test_therarbg_reads_json_listing_without_per_row_detail_fetches(self):
        """Regression: the page was gated on `<title>Search for` (no longer
        served) -> 0 rows, and every row cost one detail-page fetch."""
        good = {'pk': '97ef63', 'n': 'Dune.2021.2160p.WEBRip', 'a': 1787349022, 'c': 'Movies',
                's': 65583835282, 'se': 43, 'le': 20, 'h': HASH_A}
        rows, calls = self.run_engine('therarbg', [self.rarbg_page(
            [good, {**good, 'h': 'nothex'}, {**good, 'n': ''}, 'junk'])], 'dune%202021')
        self.assertEqual(len(calls), 1)
        self.assertIn('/get-posts/order:-se:keywords:dune%202021:format:json/?page=1', calls[0][0])
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:' + HASH_A.lower() + '&dn='))
        self.assertEqual(rows[0]['name'], 'Dune.2021.2160p.WEBRip (Movies)')
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech'], rows[0]['pub_date']),
                         (65583835282, 43, 20, 1787349022))
        self.assertEqual(rows[0]['desc_link'], 'https://therarbg.com/post-detail/97ef63/')

    def test_therarbg_is_bounded_and_keeps_category_filter(self):
        item = {'pk': 'a', 'n': 'Severance S02', 'c': 'TV', 's': 1, 'se': 1, 'le': 0, 'h': HASH_B}
        rows, calls = self.run_engine('therarbg', lambda url: self.rarbg_page([item], nxt='more'),
                                      'severance', 'tv')
        self.assertEqual(len(calls), 2)  # MAX_PAGES, although `next` never ends
        self.assertIn('category:TV:keywords:severance:format:json', calls[0][0])
        self.assertEqual(len(rows), 2)

    def test_therarbg_survives_a_non_json_body(self):
        rows, calls = self.run_engine('therarbg', ['<html>Just a moment...</html>', ''], 'dune')
        self.assertEqual(rows, [])

    # ── tokyotoshokan ────────────────────────────────────────────────────────

    def test_tokyotoshokan_challenge_page_does_not_raise_and_falls_back_to_rss(self):
        """Regression: AttributeError: 'NoneType' object has no attribute 'group'
        when search.php answered with a page that has no listing table."""
        rss = ('<?xml version="1.0"?><rss><channel><item><category>Raws</category>'
               '<title>[Raws] One Piece - 996 (1080p).mkv</title>'
               '<link><![CDATA[https://nyaa.si/download/2185858.torrent]]></link>'
               '<description><![CDATA[<a href="https://nyaa.si/download/2185858.torrent">Torrent Link</a><br />'
               '<a href="magnet:?xt=urn:btih:ECAYKJ34YBK75XJNOVUKYIKMYD557IQA&tr=udp://open.stealth.si:80/announce">'
               'Magnet Link</a><br /><a href="https://www.tokyotosho.info/details.php?id=2144475">Tokyo Tosho</a><br />'
               'Size: 468.17MB<br />]]></description></item><item><title>no magnet</title></item></channel></rss>')
        rows, calls = self.run_engine('tokyotoshokan', ['<html><title>Just a moment...</title></html>', rss],
                                      'one%20piece')
        self.assertEqual(len(calls), 2)
        self.assertIn('/search.php?terms=one+piece&type=0', calls[0][0])
        self.assertIn('/rss.php?terms=one+piece', calls[1][0])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['name'], '[Raws] One Piece - 996 (1080p).mkv')
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:ECAYKJ34'))
        self.assertEqual((rows[0]['size'], rows[0]['seeds']), ('468.17MB', -1))
        self.assertEqual(rows[0]['desc_link'], 'https://www.tokyotosho.info/details.php?id=2144475')

    def test_tokyotoshokan_empty_everything_is_zero_rows_not_a_crash(self):
        rows, _ = self.run_engine('tokyotoshokan', ['', ''], 'one%20piece')
        self.assertEqual(rows, [])

    def test_tokyotoshokan_keeps_unshaded_rows_and_real_leech_count(self):
        """Regression: `class.find("category")` as a boolean dropped every
        `category_0` row (find == 0), and the Completed count overwrote leech."""
        page = tt_page([TT_ROW.format(cls='shade category_0', b32='A' * 32, id=1),
                        TT_ROW.format(cls='category_0', b32='B' * 32, id=2)])
        rows, calls = self.run_engine('tokyotoshokan', [page], 'one%20piece', 'anime')
        self.assertEqual(len(calls), 1)
        self.assertIn('type=1', calls[0][0])
        self.assertEqual([r['desc_link'] for r in rows],
                         ['https://tokyo-tosho.net/details.php?id=1', 'https://tokyo-tosho.net/details.php?id=2'])
        self.assertEqual(rows[1]['name'], '[Raws] One Piece - 2 (1080p).mkv')
        self.assertEqual((rows[1]['seeds'], rows[1]['leech'], rows[1]['size']), ('199', '7', '468.17MB'))
        self.assertTrue(rows[1]['link'].startswith('magnet:?xt=urn:btih:' + 'B' * 32))

    def test_tokyotoshokan_stops_after_two_pages(self):
        """Regression: the old loop walked every result page (675 rows, 40s)."""
        pager = ''.join('<tr><td><a href="?lastid=2129515&amp;page={0}&amp;terms=one+piece">{0}</a></td></tr>'.format(n)
                        for n in range(2, 9))
        page = tt_page([TT_ROW.format(cls='category_0', b32='C' * 32, id=3)], pager)
        rows, calls = self.run_engine('tokyotoshokan', lambda url: page, 'one%20piece')
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[1][0].endswith('/search.php?lastid=2129515&page=2&terms=one+piece'))
        self.assertEqual(len(rows), 2)

    # ── torrentgalaxy ────────────────────────────────────────────────────────

    def test_torrentgalaxy_row_yields_magnet_and_post_detail_not_imdb_badge(self):
        rows, calls = self.run_engine('torrentgalaxy', ['<html>' + TGX_ROW + '</html>'], 'dune%202021')
        self.assertEqual(len(calls), 1)  # no "?page=2" link on the page
        self.assertEqual(calls[0][0], 'https://torrentgalaxy.info/get-posts/keywords:dune%202021/?page=1')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['link'], 'magnet:?xt=urn:btih:' + HASH_A + '&dn=Dune.2021.2160p.WEBRip&'
                         'tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce')
        self.assertEqual(rows[0]['desc_link'], 'https://torrentgalaxy.info/post-detail/97ef63/dune-2021-2160p/')
        self.assertEqual((rows[0]['name'], rows[0]['size'], rows[0]['seeds'], rows[0]['leech']),
                         ('Dune.2021.2160p.WEBRip', '61.1 GB', '43', '20'))

    def test_torrentgalaxy_is_bounded_and_filters_category(self):
        """Regression: `while True` + sleep(3) walked all 25 pages."""
        page = '<html>' + TGX_ROW + '<a href="?page=2">2</a><a href="?page=3">3</a></html>'
        rows, calls = self.run_engine('torrentgalaxy', lambda url: page, 'dune', 'movies')
        self.assertEqual(len(calls), 2)
        self.assertIn('keywords:dune:category:Movies/?page=2', calls[1][0])

    def test_torrentgalaxy_default_host_is_not_the_dead_domain(self):
        module = importlib.import_module('engines.torrentgalaxy')
        self.assertNotIn('torrentgalaxy.one', module.torrentgalaxy.url)
        self.assertTrue(module.torrentgalaxy.url.endswith('/'))  # search() formats '{url}get-posts'

    # ── torrentproject ───────────────────────────────────────────────────────

    def test_torrentproject_default_host_and_listing_row(self):
        module = importlib.import_module('engines.torrentproject')
        self.assertEqual(module.torrentproject.url, 'https://torrentproject.cc')
        page = ('<div class="tt" id="similarfiles"><div class="gac_bb"><span id="nrfound">40 results</span></div>'
                "<div><span><a href='/t3-6283766/Dune-Part-One-2021-torrent.html' title='Dune Part One 2021 torrent'>"
                'Dune Part One 2021 Bluray 1080p</a><span>Movies</span> </span> <span>29</span><span>5</span>'
                '<span>2026-03-17 09:19:14</span><span>5.4 GB</span></div></div>')
        rows, calls = self.run_engine('torrentproject', [page], 'dune%202021')
        self.assertEqual(calls[0][0], 'https://torrentproject.cc/browse?t=dune+2021&p=0')
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['desc_link'], 'https://torrentproject.cc/t3-6283766/Dune-Part-One-2021-torrent.html')
        self.assertEqual((rows[0]['name'], rows[0]['seeds'], rows[0]['leech'], rows[0]['size']),
                         ('Dune Part One 2021 Bluray 1080p', '29', '5', '5.4 GB'))

    # ── academictorrents ─────────────────────────────────────────────────────

    def academic_db(self, n_desc, n_title):
        item = ('<item><title>{t}</title><infohash>{h:040x}</infohash>'
                '<link>https://academictorrents.com/details/{h:040x}</link>'
                '<description>{d}</description><size>1047867</size></item>')
        items = [item.format(t='Dataset %d' % i, h=i, d='a wikipedia derived corpus') for i in range(n_desc)]
        items += [item.format(t='Wikipedia dump %d' % i, h=1000 + i, d='x') for i in range(n_title)]
        return ET.fromstring('<rss><channel>' + ''.join(items) + '</channel></rss>')

    def test_academictorrents_caps_matches_and_ranks_title_hits_first(self):
        """Regression: every match got its own detail fetch with no cap (683
        rows, ran to the 40s timeout)."""
        module = importlib.import_module('engines.academictorrents')
        tech = ('<tr><td>Added</td><td>2015-10-16 14:13:16</td></tr>'
                '<tr><td>Mirrors</td><td>12 complete, 3 downloading = 15 mirror(s) total</td></tr>')
        with patch.object(module.academictorrents, '_retrieve_database', lambda self: self_db):
            self_db = self.academic_db(200, 5)
            rows, calls = self.run_engine('academictorrents', lambda url: tech, 'wikipedia')
        self.assertEqual(len(rows), module.MAX_RESULTS)
        self.assertLessEqual(module.MAX_RESULTS, 50)
        self.assertEqual(len(calls), module.MAX_RESULTS)
        self.assertTrue(all(c[2].get('attempts') == 1 for c in calls))
        self.assertEqual([r['name'] for r in rows[:5]], ['Wikipedia dump %d' % i for i in range(5)])
        self.assertEqual((rows[0]['seeds'], rows[0]['leech']), (12, 3))
        self.assertTrue(rows[0]['link'].endswith('/download/%040x.torrent' % 1000))

    def test_academictorrents_keeps_rows_when_detail_page_is_missing_or_raises(self):
        """Regression: `added_date_data.group(1)` on a failed match raised inside
        the pool and aborted the whole search."""
        module = importlib.import_module('engines.academictorrents')

        def detail(url):
            if url.endswith('%040x/tech' % 1001):
                raise OSError('reset')
            return ''

        with patch.object(module.academictorrents, '_retrieve_database', lambda self: self_db):
            self_db = self.academic_db(0, 3)
            rows, _ = self.run_engine('academictorrents', detail, 'wikipedia%20dump')
        self.assertEqual([r['name'] for r in rows], ['Wikipedia dump 0', 'Wikipedia dump 1', 'Wikipedia dump 2'])
        self.assertTrue(all(r['seeds'] == -1 and r['pub_date'] == -1 for r in rows))

    def test_academictorrents_no_match_makes_no_requests(self):
        module = importlib.import_module('engines.academictorrents')
        with patch.object(module.academictorrents, '_retrieve_database', lambda self: self_db):
            self_db = self.academic_db(3, 3)
            rows, calls = self.run_engine('academictorrents', [], 'dune%202021')
        self.assertEqual((rows, calls), ([], []))

    # ── versions ─────────────────────────────────────────────────────────────

    def test_version_headers_match_versions_txt(self):
        root = Path(__file__).resolve().parents[1] / 'engines' / 'engines'
        listed = dict(line.split(': ') for line in (root / 'versions.txt').read_text().split('\n') if line)
        for name in ('knaben', 'therarbg', 'tokyotoshokan', 'torrentgalaxy', 'torrentproject', 'academictorrents'):
            header = (root / (name + '.py')).read_text().split('\n', 1)[0]
            self.assertEqual(header.replace(' ', '').upper(), '#VERSION:' + listed[name], name)


if __name__ == '__main__':
    unittest.main()
