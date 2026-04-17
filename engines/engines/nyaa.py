# VERSION: 1.5
# AUTHORS: ZigZag

import json
import urllib.parse
import urllib.request
import datetime

from novaprinter import prettyPrinter

class nyaa:
    url = 'https://nyaa.si'
    name = 'Nyaa (Anime)'
    supported_categories = {
        'all': '0_0',
        'music': '2_0',
        'software': '6_0',
    }

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
        category = self.supported_categories.get(cat, '0_0')

        for page in range(1, 4):
            params = urllib.parse.urlencode({
                'f': '0',
                'c': category,
                'q': query,
                'p': page,
            })
            url = f'{self.url}/?{params}'
            page_html = self._fetch(url)
            if not page_html:
                break

            import re
            rows = re.findall(r'<tr[^>]*class="(?:default|success|danger)"[^>]*>(.*?)</tr>', page_html, re.DOTALL)
            if not rows:
                break

            for row in rows:
                try:
                    cols = re.findall(r'<td[^>]*>(.*?)</td>', row, re.DOTALL)
                    if len(cols) < 7:
                        continue

                    # Name from second column
                    name_m = re.search(r'<a[^>]+href="/view/\d+"[^>]*(?:title="([^"]*)")?>(.*?)</a>', cols[1], re.DOTALL)
                    if not name_m:
                        continue
                    name = name_m.group(1) or re.sub(r'<[^>]+>', '', name_m.group(2)).strip()

                    # Magnet link
                    mag_m = re.search(r'href="(magnet:\?[^"]+)"', cols[2], re.DOTALL)
                    if not mag_m:
                        continue
                    magnet = mag_m.group(1).replace('&amp;', '&')

                    # Size
                    size_text = re.sub(r'<[^>]+>', '', cols[3]).strip()
                    size_bytes = self._parse_size(size_text)

                    seeds = re.sub(r'<[^>]+>', '', cols[5]).strip()
                    leech = re.sub(r'<[^>]+>', '', cols[6]).strip()

                    prettyPrinter({
                        'link': magnet,
                        'name': name,
                        'size': str(size_bytes),
                        'seeds': seeds,
                        'leech': leech,
                        'engine_url': self.url,
                        'desc_link': self.url,
                    })
                except Exception:
                    continue

    def _parse_size(self, s):
        import re as re2
        s = s.replace('\xa0', ' ').strip()
        m = re2.match(r'([\d.]+)\s*(GiB|MiB|KiB|TiB|GB|MB|KB|B)', s, re2.I)
        if not m:
            return 0
        val = float(m.group(1))
        unit = m.group(2).upper()
        if 'T' in unit:
            return int(val * 1099511627776)
        elif 'G' in unit:
            return int(val * 1073741824)
        elif 'M' in unit:
            return int(val * 1048576)
        elif 'K' in unit:
            return int(val * 1024)
        return int(val)
