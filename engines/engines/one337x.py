# VERSION: 2.5
# AUTHORS: ZigZag

import re
import urllib.parse
import urllib.request
import http.client
import html
import datetime

from novaprinter import prettyPrinter

class one337x:
    url = 'https://1337x.to'
    name = '1337x'
    supported_categories = {
        'all': '',
        'movies': '/category-search/{query}/Movies/{page}/',
        'music': '/category-search/{query}/Music/{page}/',
        'games': '/category-search/{query}/Games/{page}/',
        'software': '/category-search/{query}/Apps/{page}/',
    }

    trackers_list = [
        'udp://tracker.opentrackr.org:1337/announce',
        'udp://open.stealth.si:80/announce',
        'udp://tracker.openbittorrent.com:6969/announce',
        'udp://exodus.desync.com:6969/announce',
        'udp://tracker.torrent.eu.org:451/announce',
    ]
    trackers = '&'.join(urllib.parse.urlencode({'tr': t}) for t in trackers_list)

    def _get_ua(self):
        base = datetime.date(2024, 4, 16)
        ver = 125 + ((datetime.date.today() - base).days // 30)
        return f"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:{ver}.0) Gecko/20100101 Firefox/{ver}.0"

    def _fetch(self, url):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': self._get_ua()})
            resp = urllib.request.urlopen(req, timeout=10)
            return resp.read().decode('utf-8', 'replace')
        except Exception:
            return ''

    def search(self, what, cat='all'):
        query = urllib.parse.unquote(what)
        for page in range(1, 4):  # 3 pages
            if cat != 'all' and cat in self.supported_categories:
                path = self.supported_categories[cat].format(query=urllib.parse.quote(query), page=page)
            else:
                path = f'/search/{urllib.parse.quote(query)}/{page}/'

            page_html = self._fetch(self.url + path)
            if not page_html:
                break

            rows = re.findall(r'<tr>(.*?)</tr>', page_html, re.DOTALL)
            found = False
            for row in rows:
                try:
                    name_m = re.search(r'class="name".*?<a href="(/torrent/[^"]+)"[^>]*>(.*?)</a>', row, re.DOTALL)
                    if not name_m:
                        continue
                    detail_path = name_m.group(1)
                    name = html.unescape(re.sub(r'<[^>]+>', '', name_m.group(2)).strip())

                    cols = re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL)
                    if len(cols) < 5:
                        continue

                    seeds = re.sub(r'<[^>]+>', '', cols[1]).strip()
                    leech = re.sub(r'<[^>]+>', '', cols[2]).strip()
                    size_raw = re.sub(r'<[^>]+>', '', cols[4]).strip()

                    # Parse size to bytes
                    size_bytes = self._parse_size(size_raw)

                    # Get magnet from detail page
                    detail_html = self._fetch(self.url + detail_path)
                    mag_m = re.search(r'"(magnet:\?[^"]+)"', detail_html)
                    if not mag_m:
                        continue
                    magnet = html.unescape(mag_m.group(1))

                    prettyPrinter({
                        'link': magnet,
                        'name': name,
                        'size': str(size_bytes),
                        'seeds': seeds,
                        'leech': leech,
                        'engine_url': self.url,
                        'desc_link': self.url + detail_path,
                    })
                    found = True
                except Exception:
                    continue

            if not found:
                break

    def _parse_size(self, s):
        s = s.replace('\xa0', ' ').strip()
        m = re.match(r'([\d.]+)\s*(GB|MB|KB|B)', s, re.I)
        if not m:
            return 0
        val = float(m.group(1))
        unit = m.group(2).upper()
        if unit == 'GB':
            return int(val * 1073741824)
        elif unit == 'MB':
            return int(val * 1048576)
        elif unit == 'KB':
            return int(val * 1024)
        return int(val)