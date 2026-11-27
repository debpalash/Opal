# VERSION: 2.10
# AUTHORS: nKlido

# LICENSING INFORMATION
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import re
from datetime import datetime

from helpers import retrieve_url
from novaprinter import prettyPrinter


class solidtorrents:
    # solidtorrents.to merged into BitSearch: it 301s to bitsearch.to, which
    # 301s to bitsearch.eu, and serves BitSearch's card markup. The old
    # `search-result` / `dl-magnet` parser matched nothing there (0 rows).
    # This engine keeps its own identity by asking for the seeders-sorted view.
    url = 'https://bitsearch.eu'
    name = 'Solid Torrents'
    supported_categories = {'all': '', 'music': '7', 'books': '9'}

    _CARD = re.compile(
        r'<div class="[^"]*\btorrent-result-card\b.*?<!-- Mobile', re.S)
    _TITLE = re.compile(r'<a href="(/torrent/[^"]+)"[^>]*>\s*(.*?)\s*</a>', re.S)
    _MAGNET = re.compile(r'href="(magnet:\?[^"]+)"')
    _SIZE = re.compile(r'fa-download"></i>\s*<span>\s*([0-9.,]+\s*[KMGT]?B)\s*</span>')
    _DATE = re.compile(r'fa-calendar"></i>\s*<span>\s*(\d{1,2})/(\d{1,2})/(\d{4})\s*</span>')
    _SEEDS = re.compile(r'fa-arrow-up"></i>\s*(?:<span[^>]*>\s*){1,2}([0-9,]+)')
    _LEECH = re.compile(r'fa-arrow-down"></i>\s*(?:<span[^>]*>\s*){1,2}([0-9,]+)')

    def parse(self, page: str) -> int:
        """Print one row per result card; returns the number printed."""
        total = 0
        for card in self._CARD.findall(page):
            title, magnet = self._TITLE.search(card), self._MAGNET.search(card)
            if not title or not magnet:
                continue
            name = ' '.join(re.sub(r'<[^>]+>', '', title.group(2)).split())
            if not name:
                continue

            def number(pattern: 're.Pattern[str]') -> int:
                m = pattern.search(card)
                return int(m.group(1).replace(',', '')) if m else -1

            size = self._SIZE.search(card)
            date = self._DATE.search(card)
            pub_date = -1
            if date:
                try:
                    pub_date = int(datetime(int(date.group(3)), int(date.group(1)),
                                            int(date.group(2))).timestamp())
                except (ValueError, OverflowError):
                    pass
            prettyPrinter({
                'link': magnet.group(1),
                'name': name,
                'size': size.group(1).replace(',', '') if size else '-1',
                'seeds': number(self._SEEDS),
                'leech': number(self._LEECH),
                'engine_url': self.url,
                'desc_link': self.url.rstrip('/') + title.group(1),
                'pub_date': pub_date,
            })
            total += 1
        return total

    def request(self, searchTerm: str, category: str, page: int = 1) -> str:
        return retrieve_url(
            self.url.rstrip('/') + '/search?q=' + searchTerm.replace('%20', '+')
            + ('&category=' + category if category else '')
            + '&sortBy=seeders&page=' + str(page))

    def search(self, what: str, cat: str = 'all') -> None:
        category = self.supported_categories[cat]

        for page in range(1, 3):
            if self.parse(self.request(what, category, page)) < 15:
                break
