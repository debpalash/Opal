"""New torrent engines: request shape and parsing, with no provider network.

Every fixture below is a trimmed excerpt of a real response captured from the
provider on 2026-11-18 (markup and field names untouched, rows cut down).
"""
import importlib
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'engines'))

H1 = 'dafc8c076ca2f3ed376eeae7c76a0d6be2415c45'
H2 = 'e1fc140a6391357fa1cf08ddb70274f9c05eb88b'

ANIRENA = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>AniRena</title>
  <item>
    <title>[Anime &gt; Subtitle(s) and/or Audio(s)] Kikansha no Mahou wa Tokubetsu desu 2nd Season - 07 [480p CR WEB-DL AVC AAC][MultiSub][8498D8E4]</title>
    <link>https://www.anirena.com/torrent/01a1efa9-6eb6-738d-a11f-2c4d53e72c90</link>
    <guid isPermaLink="true">https://www.anirena.com/torrent/01a1efa9-6eb6-738d-a11f-2c4d53e72c90</guid>
    <pubDate>Wed, 18 Nov 2026 17:17:00 +0000</pubDate>
    <description><![CDATA[Size: 395.7 MB | Uploader: Erai-raws | Category: Anime &gt; Subtitle(s) and/or Audio(s)]]></description>
    <enclosure url="https://www.anirena.com/torrents/01a1efa9-6eb6-738d-a11f-2c4d53e72c90.torrent" type="application/x-bittorrent" length="0"/>
  </item>
  <item><title>[Anime &gt; Raw] Offsite</title><link>https://www.anirena.com/torrent/x</link>
    <enclosure url="https://elsewhere.invalid/torrents/x.torrent" type="application/x-bittorrent" length="0"/></item>
</channel></rss>'''

KISSSUB = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel><title><![CDATA[naruto]]></title>
<item>
    <title><![CDATA[火影忍者疾风传.阿拉伯语.无字幕.Naruto.Shippuden.2007.1080p.Starz.WEB-DL.AAC2.0.HEVC-GST]]></title>
    <link>http://www.kisssub.org/show-5921e048f8f587be1c0600f258cc50eb9c4237e9.html</link>
    <guid isPermaLink="true">http://www.kisssub.org/show-5921e048f8f587be1c0600f258cc50eb9c4237e9.html</guid>
    <author><![CDATA[zifang110]]></author>
        <enclosure url="http://v2.uploadbt.com/?r=down&amp;hash=5921e048f8f587be1c0600f258cc50eb9c4237e9" type="application/x-bittorrent" />
        <pubDate>Tue, 12 May 2026 21:30:45 +0800</pubDate>
    <category domain="http://www.kisssub.org/sort-1-1.html"><![CDATA[动画]]></category>
</item>
<item><title><![CDATA[No hash here]]></title><link>http://www.kisssub.org/show-nothing.html</link></item>
</channel></rss>'''

FITGIRL = '''<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"
	xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
<channel><title>Search Results for &#8220;witcher&#8221; &#8211; FitGirl Repacks</title>
	<item>
		<title>Updates Digest for October 29, 2026</title>
		<link>https://fitgirl-repacks.site/updates-digest-for-october-29-2026/</link>
		<pubDate>Fri, 30 Oct 2026 13:30:09 +0000</pubDate>
		<content:encoded><![CDATA[<p>All updates can be found on their own page.</p>]]></content:encoded>
	</item>
	<item>
		<title>REKA: Deluxe Edition &#8211; v1.0.21 + Bonus OST</title>
		<link>https://fitgirl-repacks.site/reka/</link>
		<dc:creator><![CDATA[FitGirl]]></dc:creator>
		<pubDate>Tue, 27 Oct 2026 22:37:57 +0000</pubDate>
		<content:encoded><![CDATA[<h3>#7275 REKA: Deluxe Edition v1.0.21 + Bonus OST</h3>
<p>Languages: <strong>RUS/ENG/MULTI9</strong><br />
Original Size: <strong>3.6 GB</strong><br />
Repack Size: <strong>1.2 GB</strong></p>
<h3>Download Mirrors (Torrent)</h3>
<ul>
<li><a href="https://1337x.to/torrent/6747872/REKA-Deluxe-Edition-v1-0-21-Bonus-OST-MULTi9-FitGirl-Repack/" target="_blank">1337x</a> | [<a href="magnet:?xt=urn:btih:30AFD46AE9632EE649967E9694205AAD38031E21&#038;dn=REKA%3A+Deluxe+Edition+%28v1.0.21+%2B+Bonus+OST%2C+MULTi9%29+%5BFitGirl+Repack%5D&#038;tr=udp%3A%2F%2Fopentor.net%3A6969%2Fannounce&#038;tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce">magnet</a>]</li>
</ul>]]></content:encoded>
	</item>
</channel></rss>'''

FOSS = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel>
        <item>
            <title>0 A.D. 0.28.0 - Windows (x86_64)</title>
            <description>Torrent for 0ad - Windows (x86_64)</description>
            <link>https://fosstorrents.com/direct-files/0ad-0.28.0-win32.exe.torrent</link>
            <guid isPermaLink="false">f279221e11f0bb27e87dddecc18a5303f920b0a4b19ff5aae0be1b2bf0409d7b</guid>
            <pubDate>Wed, 11 Mar 2026 01:59:14 -0300</pubDate>
        </item>
        <item>
            <title>Kubuntu 26.10 - Kubuntu (amd64)</title>
            <description>Torrent for kubuntu - Kubuntu (amd64)</description>
            <link>https://fosstorrents.com/direct-files/kubuntu-26.10-desktop-amd64.iso.torrent</link>
            <pubDate>Sun, 18 Oct 2026 08:39:18 -0300</pubDate>
        </item>
</channel></rss>'''

LINUXTRACKER = '''<table><tbody>
        <tr>
          <td class="torrent-name-cell">
            <a class="torrent-name" href="/torrents/dafc8c076ca2f3ed376eeae7c76a0d6be2415c45/">ubuntu-26.04-desktop-amd64.iso</a>
            <span class="torrent-mobile-meta">Ubuntu · 6.1 GB · Oct 25, 2026</span>
          </td>
          <td><span class="category-badge">Ubuntu</span></td>
          <td class="muted-cell">Oct 25, 2026</td>
          <td class="numeric muted-cell">6.1 GB</td>
          <td class="numeric seeds stat-stack">
            <strong>11</strong>
            
            <small>+2334 ext</small>
            
          </td>
          <td class="numeric leeches stat-stack">
            <strong>0</strong>
            
            <small>+20 ext</small>
            
          </td>
          <td class="numeric stat-stack">
            <strong>21</strong>
            
          </td>
        </tr>
      
        <tr>
          <td class="torrent-name-cell">
            <a class="torrent-name" href="/torrents/e1fc140a6391357fa1cf08ddb70274f9c05eb88b/">ubuntu-26.04-live-server-amd64.iso</a>
          </td>
          <td class="numeric muted-cell">2.7 GB</td>
          <td class="numeric seeds stat-stack">
            <strong>6</strong>
          </td>
          <td class="numeric leeches stat-stack">
            <strong>0</strong>
          </td>
        </tr>
</tbody></table>'''

ANILIBRIA_SEARCH = json.dumps([{
    'id': 413, 'type': {'value': 'TV'}, 'year': 2007,
    'name': {'main': 'Наруто Ураганные хроники', 'english': 'Naruto: Shippuuden', 'alternative': None},
    'alias': 'naruto-shippuuden-naruto-uragannye-khroniki'}, {'id': 'bad'}])
ANILIBRIA_TORRENTS = json.dumps([{
    'id': 6892, 'hash': '5bc94db3566c3934bff688fd3b7a861c4ac1c862', 'size': 52787876553,
    'label': 'Naruto- Shippuuden - AniLiberty.TOP [HDTVRip 720p][AVC][370-500]',
    'magnet': 'magnet:?xt=urn:btih:5bc94db3566c3934bff688fd3b7a861c4ac1c862&dn=Naruto-+Shippuuden+-+AniLiberty.TOP+%5BHDTVRip+720p%5D%5BAVC%5D%5B370-500%5D&xl=52787876553&tr=http://tr.libria.fun:2710/announce&tr=http://retracker.local/announce',
    'seeders': 13, 'leechers': 0, 'created_at': '2019-05-01T17:53:00+00:00'},
    {'id': 1, 'label': 'No magnet', 'magnet': 'javascript:alert(1)'}])

ABB_LIST = '''<div id="content">
<div class="post"><div class="postTitle"><h2><a href="/abss/der-fall-von-gondolin-jrr-tolkien/" rel="bookmark">Der Fall von Gondolin - J.R.R. Tolkien</a></h2></div><div class="postInfo">Category: Fantasy&nbsp; <br />Language: German<span style="margin-left:100px;">Keywords: J.R.R.&nbsp Tolkien&nbsp </span><br /></div><div class="postContent"><div class="center">
<p class="center"><a href="https://audiobookbay.lu/abss/der-fall-von-gondolin-jrr-tolkien/"><img src="https://s1.directupload.eu/images/user/261014/jisn3usi.jpg" alt="J.R.R. Tolkien Der Fall von Gondolin" width="250" /></a></p>
</div>
<p style='text-align:center;'>Posted: 14 Oct 2026<br />Format: <span style='color:#a00;'>MP3</span> / Bitrate: <span style='color:#a00;'>128 Kbps</span><br />File Size: <span style='color:#00f;'>531.35</span> MBs</p>
</div></div><div class="post"><div class="postTitle"><h2><a href="/abss/der-untergang-von-numenor-jrr-tolkien/" rel="bookmark">Der Untergang von Númenor - J.R.R. Tolkien</a></h2></div><div class="postInfo">Category: Fantasy&nbsp;</div></div>'''
ABB_DETAIL = '''<table>
<tr>
<td style='width:150px;'>Announce URL:</td>
<td style='width:323px;'>udp://tracker.torrent.eu.org:451/announce</td>
</tr>
<tr>
<td>Tracker:</td>
<td>udp://tracker.torrent.eu.org:451/announce</td>
</tr>
<tr>
<td>Tracker:</td>
<td>udp://open.stealth.si:80/announce</td>
</tr>
<tr>
<td>Info Hash:</td>
<td>ff13b61127364816a9b349d83c483122122f77ce</td>
</tr>
</table>'''

NNM_LIST = '''<table>
<tr class="prow1">
		<td align="center"><a class="gen" href="tracker.php?f=433&nm=ubuntu">Компьютерная литература</a></td>
				<td title="" class="genmed"><a class="genmed topictitle" href="viewtopic.php?t=134581"><b>Ubuntu | Официальный учебный курс (2008) [DJVU]</b></a>&nbsp;<span class="gensmall" title="Платиновая раздача"></span></td>
				<td align="center"><a class="genmed" href="tracker.php?pid=346105">Al_Vasif</a></td>
				<td align="center" nowrap="nowrap"><a href="download.php?id=133304" rel="nofollow" class="genmed">[ <b>DL</b> ]</a></td>
		<td align="center" title=" 0.1&nbsp;KB/s " nowrap="nowrap" class="gensmall"><u>14393510</u> 13.7 MB</td>
				<td align="center" title="Seeders" class="seedmed"><b>47</b></td>
		<td align="center" title="Leechers" class="leechmed"><b>0</b></td>
		<td align="center" title="10504 Просмотров" class="gensmall">21</td>
				<td align="center" nowrap="nowrap" title="Торрент-файл добавлен" class="gensmall"><u>1792312848</u> 18-10-2026<br>11:40</td>
					</tr>
</table>'''
NNM_TOPIC = ('<span class="genmed"><b><a href="download.php?id=1430708" rel="nofollow">Скачать</a></b></span><br /><br /><br />'
             '<!--noindex--><a rel="nofollow" href="magnet:?xt=urn:btih:7B3EF32CD684FA3A85F114AA83E6CF50F2B5BE90" title="Примагнититься">')

# TorrentKitty result table: one usable row, a repeat of the same hash, and a
# row whose action cell has no magnet (must be dropped).
KITTY = ('<table id="archiveResult"><tr><th>Name</th><th>Size</th><th>Date</th><th>Action</th></tr>'
         + ''.join('<tr><td class="name">ubuntu-26.04-live-server-amd64.iso</td><td class="size">3.1 kb</td>'
                   '<td class="date">2026-07-20</td><td class="action"><a href="/information/' + H2.upper() + '">Detail</a>'
                   '<a href="magnet:?xt=urn:btih:' + H2.upper() + '&dn=ubuntu-26.04-live-server-amd64.iso&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce" rel="magnet">Open</a></td></tr>'
                   for _ in range(2))
         + '<tr><td class="name">no magnet here</td><td class="size">1 kb</td><td class="date">2026-07-20</td>'
         '<td class="action"><a href="/information/zz">Detail</a></td></tr></table>')

NEW_ENGINES = ['anilibria', 'anirena', 'audiobookbay', 'fitgirl', 'fosstorrents',
               'kisssub', 'linuxtracker', 'nnmclub', 'torrentkitty']


class NewTorrentEngines(unittest.TestCase):
    def run_engine(self, name, route, query, category='all', base=None):
        """`route(url)` returns the body for a URL (thread-safe: detail pages
        are fetched from a small pool, so call order is not deterministic)."""
        module = importlib.import_module('engines.' + name)
        rows, calls = [], []
        def fetch(url, *args, **kwargs):
            calls.append(url)
            return route(url)
        engine = getattr(module, name)()
        if base:
            engine.url = base
        with patch.object(module, 'retrieve_url', fetch), patch.object(module, 'prettyPrinter', rows.append):
            engine.search(query, category)
        return rows, calls

    def test_anirena_emits_onsite_torrent_with_feed_size_and_strips_category_prefix(self):
        rows, calls = self.run_engine('anirena', lambda u: ANIRENA, 'Naruto%20dub%26sub')
        self.assertEqual(calls, ['https://www.anirena.com/rss?s=Naruto+dub%26sub'])
        self.assertEqual(len(rows), 1)  # the off-site enclosure is refused
        self.assertEqual(rows[0]['link'], 'https://www.anirena.com/torrents/01a1efa9-6eb6-738d-a11f-2c4d53e72c90.torrent')
        self.assertTrue(rows[0]['name'].startswith('Kikansha no Mahou wa Tokubetsu desu 2nd Season - 07'))
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech']), ('395.7 MB', -1, -1))
        self.assertEqual(rows[0]['pub_date'], 1795022220)

    def test_kisssub_builds_magnet_from_published_hash_only(self):
        rows, calls = self.run_engine('kisssub', lambda u: KISSSUB, 'one%20piece')
        self.assertEqual(calls, ['https://www.kisssub.org/rss-one%20piece.xml'])
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:5921e048f8f587be1c0600f258cc50eb9c4237e9&dn='))
        self.assertEqual(rows[0]['desc_link'], 'https://www.kisssub.org/show-5921e048f8f587be1c0600f258cc50eb9c4237e9.html')
        self.assertEqual((rows[0]['size'], rows[0]['seeds']), (-1, -1))

    def test_fitgirl_takes_post_magnet_and_repack_size_and_skips_digest_posts(self):
        rows, calls = self.run_engine('fitgirl', lambda u: FITGIRL, 'witcher%203', 'games')
        self.assertEqual(calls, ['https://fitgirl-repacks.site/?s=witcher+3&feed=rss2'])
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:30afd46ae9632ee649967e9694205aad38031e21&dn='))
        self.assertIn('tr=udp:%2F%2Fopentor.net:6969%2Fannounce', rows[0]['link'])
        self.assertEqual(rows[0]['name'], 'REKA: Deluxe Edition (v1.0.21 + Bonus OST, MULTi9) [FitGirl Repack]')
        self.assertEqual(rows[0]['size'], '1.2 GB')
        self.assertEqual(rows[0]['desc_link'], 'https://fitgirl-repacks.site/reka/')

    def test_fosstorrents_matches_every_query_word_locally(self):
        rows, calls = self.run_engine('fosstorrents', lambda u: FOSS, 'kubuntu%20AMD64', 'software')
        self.assertEqual(calls, ['https://fosstorrents.com/feed/torrents.xml'])
        self.assertEqual([r['link'] for r in rows],
                         ['https://fosstorrents.com/direct-files/kubuntu-26.10-desktop-amd64.iso.torrent'])
        self.assertEqual(rows[0]['name'], 'Kubuntu 26.10 - Kubuntu (amd64)')
        rows, _ = self.run_engine('fosstorrents', lambda u: FOSS, 'kubuntu%20windows')
        self.assertEqual(rows, [])

    def test_linuxtracker_sums_tracker_and_external_swarm(self):
        rows, calls = self.run_engine('linuxtracker', lambda u: LINUXTRACKER, 'ubuntu%2026.04')
        self.assertEqual(calls, ['https://linuxtracker.org/torrents/?q=ubuntu+26.04'])
        self.assertEqual(len(rows), 2)
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:' + H1 + '&dn=ubuntu-26.04-desktop-amd64.iso&tr='))
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech']), ('6.1 GB', 2345, 20))
        self.assertEqual((rows[1]['size'], rows[1]['seeds'], rows[1]['leech']), ('2.7 GB', 6, 0))
        self.assertEqual(rows[1]['desc_link'], 'https://linuxtracker.org/torrents/' + H2 + '/')

    def test_anilibria_lists_release_torrents_with_provider_swarm(self):
        def route(url):
            return ANILIBRIA_TORRENTS if '/anime/torrents/release/413' in url else ANILIBRIA_SEARCH
        rows, calls = self.run_engine('anilibria', route, 'naruto%20%26', 'anime')
        self.assertEqual(calls[0], 'https://anilibria.top/api/v1/app/search/releases?query=naruto+%26')
        self.assertEqual(calls[1:], ['https://anilibria.top/api/v1/anime/torrents/release/413'])
        self.assertEqual(len(rows), 1)  # the non-magnet row is refused
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:5bc94db3566c3934bff688fd3b7a861c4ac1c862&'))
        self.assertEqual(rows[0]['name'], 'Naruto- Shippuuden - AniLiberty.TOP [HDTVRip 720p][AVC][370-500]')
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech']), (52787876553, 13, 0))
        self.assertEqual(rows[0]['pub_date'], 1556733180)
        self.assertEqual(rows[0]['desc_link'],
                         'https://anilibria.top/anime/releases/release/naruto-shippuuden-naruto-uragannye-khroniki')

    def test_audiobookbay_reads_hash_and_trackers_from_the_book_page(self):
        def route(url):
            if url.endswith('/abss/der-fall-von-gondolin-jrr-tolkien/'):
                return ABB_DETAIL
            return '' if '/abss/' in url else ABB_LIST
        rows, calls = self.run_engine('audiobookbay', route, 'Tolkien', 'books')
        self.assertEqual(calls[0], 'https://audiobookbay.lu/?s=tolkien')
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(rows), 1)  # the book whose page failed is dropped
        self.assertEqual(rows[0]['link'],
                         'magnet:?xt=urn:btih:ff13b61127364816a9b349d83c483122122f77ce'
                         '&dn=Der+Fall+von+Gondolin+-+J.R.R.+Tolkien'
                         '&tr=udp:%2F%2Ftracker.torrent.eu.org:451%2Fannounce&tr=udp:%2F%2Fopen.stealth.si:80%2Fannounce')
        self.assertEqual((rows[0]['size'], rows[0]['seeds']), ('531.35 MB', -1))

    def test_nnmclub_encodes_query_as_cp1251_and_keeps_table_swarm(self):
        rows, calls = self.run_engine('nnmclub', lambda u: NNM_TOPIC if 'viewtopic' in u else NNM_LIST,
                                      '%D0%BC%D0%B0%D1%82%D1%80%D0%B8%D1%86%D0%B0')  # "матрица"
        self.assertEqual(calls[0], 'https://nnmclub.to/forum/tracker.php?nm=%EC%E0%F2%F0%E8%F6%E0&o=10&s=2')
        self.assertEqual(calls[1:], ['https://nnmclub.to/forum/viewtopic.php?t=134581'])
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:7b3ef32cd684fa3a85f114aa83e6cf50f2b5be90&dn='))
        self.assertEqual(rows[0]['name'], 'Ubuntu Официальный учебный курс (2008) [DJVU]')
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech'], rows[0]['pub_date']),
                         (14393510, 47, 0, 1792312848))

    def test_torrentkitty_keeps_row_magnet_and_leaves_size_unknown(self):
        rows, calls = self.run_engine('torrentkitty', lambda u: KITTY, 'ubuntu%20server')
        self.assertEqual(calls, ['https://www.torrentkitty.tv/search/ubuntu%20server/'])
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]['link'].startswith('magnet:?xt=urn:btih:' + H2 + '&dn=ubuntu-26.04-live-server-amd64.iso&tr='))
        self.assertEqual((rows[0]['size'], rows[0]['seeds'], rows[0]['leech']), (-1, -1, -1))
        self.assertEqual(rows[0]['desc_link'], 'https://www.torrentkitty.tv/information/' + H2.upper())
        self.assertEqual(rows[0]['pub_date'], 1784505600)

    def test_every_engine_honours_a_configured_mirror_base(self):
        for name in NEW_ENGINES:
            _, calls = self.run_engine(name, lambda u: '', 'naruto', base='https://mirror.example.test')
            self.assertEqual(len(calls), 1, name)
            self.assertTrue(calls[0].startswith('https://mirror.example.test/'), name)

    def test_empty_garbage_or_entity_bearing_bodies_emit_nothing(self):
        bodies = ['', 'not a response', '{"error": "offline"}',
                  '<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss><channel><item><title>&x;</title></item></channel></rss>']
        for name in NEW_ENGINES:
            for body in bodies:
                rows, _ = self.run_engine(name, lambda u, body=body: body, 'naruto')
                self.assertEqual(rows, [], name)

    def test_unsupported_category_and_blank_query_never_touch_the_network(self):
        for name, category in [('anirena', 'music'), ('kisssub', 'books'), ('fitgirl', 'movies'),
                               ('fosstorrents', 'movies'), ('linuxtracker', 'games'), ('anilibria', 'software'),
                               ('audiobookbay', 'movies'), ('torrentkitty', 'movies'), ('nnmclub', 'pictures')]:
            rows, calls = self.run_engine(name, lambda u: '', 'naruto', category)
            self.assertEqual((rows, calls), ([], []), name)
            rows, calls = self.run_engine(name, lambda u: '', '%20%20')
            self.assertEqual((rows, calls), ([], []), name)

    def test_rows_survive_the_real_printer_as_eight_field_lines(self):
        import novaprinter
        module = importlib.import_module('engines.linuxtracker')
        lines = []
        def capture(row):
            fields = [row['link'], row['name'].replace('|', ' '), str(novaprinter.anySizeToBytes(row['size'])),
                      str(row['seeds']), str(row['leech']), row['engine_url'], row.get('desc_link', ''),
                      str(row.get('pub_date', -1))]
            lines.append('|'.join(fields))
        with patch.object(module, 'retrieve_url', lambda *a, **k: LINUXTRACKER), patch.object(module, 'prettyPrinter', capture):
            module.linuxtracker().search('ubuntu')
        self.assertEqual([line.count('|') for line in lines], [7, 7])
        self.assertEqual(lines[0].split('|')[2], str(int(6.1 * 1024 ** 3)))

    def test_magnet_helper_refuses_anything_but_a_40_hex_hash(self):
        import opal_torrent_util as util
        self.assertEqual(util.magnet_from_hash('abc'), '')
        self.assertEqual(util.magnet_from_hash(H1 + '&tr=x'), '')
        self.assertEqual(util.magnet_from_hash(H1.upper(), 'A & B', ()), 'magnet:?xt=urn:btih:' + H1 + '&dn=A+%26+B')
        self.assertEqual(util.fetch_many(lambda u: 1 / 0, ['a', 'b']), ['', ''])
        self.assertEqual((util.rfc822_epoch('nope'), util.ymd_epoch('2026-13-40')), (-1, -1))


if __name__ == '__main__':
    unittest.main()
